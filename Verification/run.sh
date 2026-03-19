#!/usr/bin/env bash

set -u

SPEC="specs/sram_controller_2025-11-03_08-29-11.json"
MAX_ITERS="${TB_CHECKER_MAX_ITERS:-10}"
LOG_DIR="logs"
VERBOSE=0
CLEAN_ONLY=0
MAX_RETRIES=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    -Spec|--spec)
      SPEC="$2"
      shift 2
      ;;
    -MaxIters|--max-iters)
      MAX_ITERS="$2"
      shift 2
      ;;
    -LogDir|--log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    -Verbose|--verbose)
      VERBOSE=1
      shift
      ;;
    -CleanOnly|--clean-only)
      CLEAN_ONLY=1
      shift
      ;;
    -MaxRetries|--max-retries)
      MAX_RETRIES="$2"
      shift 2
      ;;
    *)
      echo "[run.sh] Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${LLM_PROVIDER:-}" ]]; then
  export LLM_PROVIDER="tamu"
fi
if [[ -n "${TAMUS_AI_MODEL:-}" ]]; then
  export LLM_MODEL="${LLM_MODEL:-$TAMUS_AI_MODEL}"
  export TB_ENGINEER_MODEL="${TB_ENGINEER_MODEL:-$TAMUS_AI_MODEL}"
  export TB_CHECKER_MODEL="${TB_CHECKER_MODEL:-$TAMUS_AI_MODEL}"
fi
export PYTHONUNBUFFERED=1

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  else
    PYTHON_BIN="python"
  fi
fi

GEN_LOG="$LOG_DIR/01_generate_tb.log"
COMP_LOG="$LOG_DIR/02_compile.log"
FIX_LOG="$LOG_DIR/02_compile_fix.log"
SIM_LOG="$LOG_DIR/03_sim.log"
SIM_FIX_LOG="$LOG_DIR/03_sim_fix.log"

echo "=== TB RUNNER ==="
echo "Spec:        $SPEC"
echo "Max iters:   $MAX_ITERS"
echo "Logs:        $LOG_DIR"
echo ""

mkdir -p build "$LOG_DIR"

fail_and_exit() {
  local stage="$1"
  local code="$2"
  local log_path="$3"
  echo ""
  echo "[$stage] FAILED (exit code $code)" >&2
  if [[ -f "$log_path" ]]; then
    echo "See log: $log_path" >&2
  fi
  exit "$code"
}

test_retryable_failure() {
  local pattern
  local path
  for path in "$@"; do
    [[ -f "$path" ]] || continue
    for pattern in "RemoteException" "Read timed out" "timed out" "timeout" "HTTP 524" "Checker JSON parse failed"; do
      if grep -qi "$pattern" "$path"; then
        return 0
      fi
    done
  done
  return 1
}

clear_run_artifacts() {
  rm -f \
    "$LOG_DIR/01_generate_tb.log" \
    "$LOG_DIR/02_compile.log" \
    "$LOG_DIR/02_compile_fix.log" \
    "$LOG_DIR/03_sim.log" \
    "$LOG_DIR/03_sim_fix.log" \
    build/tb_gen.sv \
    build/tb_gen_syntax.sv \
    build/auto_stub_dut.sv \
    build/filelist.f \
    build/sim
}

if [[ "$CLEAN_ONLY" -eq 1 ]]; then
  clear_run_artifacts
  echo "Cleanup complete for LogDir '$LOG_DIR'."
  exit 0
fi

for (( attempt=1; attempt<=MAX_RETRIES; attempt++ )); do
  if [[ "$attempt" -gt 1 ]]; then
    echo ""
    echo "=== RETRY $attempt/$MAX_RETRIES ==="
    clear_run_artifacts
  fi

  echo "[1/3] Generate TB from $SPEC"
  if ! "$PYTHON_BIN" runner/generate_tb.py --spec "$SPEC" --out build/tb_gen.sv --max-iters "$MAX_ITERS" \
      2>&1 | tee "$GEN_LOG"; then
    if test_retryable_failure "$GEN_LOG" && [[ "$attempt" -lt "$MAX_RETRIES" ]]; then
      echo "[1/3] Generate TB: RETRYING due to transient error"
      continue
    fi
    fail_and_exit "Generate TB" "${PIPESTATUS[0]}" "$GEN_LOG"
  fi

  echo "[1/3] Generate TB: SUCCESS"
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "--- generate_tb.py (tail) ---"
    tail -n 15 "$GEN_LOG"
    echo "--------------------------------"
  fi

  echo ""
  echo "[2/3] Compile"
  FL="build/filelist.f"
  if [[ ! -f "$FL" ]]; then
    echo "ERROR: filelist '$FL' not found. Generation must have failed." >&2
    fail_and_exit "Compile (missing filelist)" 2 "$GEN_LOG"
  fi

  if ! iverilog -g2012 -f "$FL" -o build/sim 2>&1 | tee "$COMP_LOG"; then
    echo "[2/3] Compile: FAILED, attempting auto-fix..."
    if ! "$PYTHON_BIN" runner/compile_fix.py --tb build/tb_gen.sv --filelist "$FL" --max-iters "$MAX_ITERS" \
        2>&1 | tee "$FIX_LOG"; then
      if test_retryable_failure "$FIX_LOG" "$COMP_LOG" && [[ "$attempt" -lt "$MAX_RETRIES" ]]; then
        echo "[2/3] Compile: RETRYING due to transient error"
        continue
      fi
      fail_and_exit "Compile (auto-fix failed)" "${PIPESTATUS[0]}" "$FIX_LOG"
    fi

    if ! iverilog -g2012 -f "$FL" -o build/sim 2>&1 | tee "$COMP_LOG"; then
      if test_retryable_failure "$COMP_LOG" && [[ "$attempt" -lt "$MAX_RETRIES" ]]; then
        echo "[2/3] Compile: RETRYING due to transient error"
        continue
      fi
      fail_and_exit "Compile (after auto-fix)" "${PIPESTATUS[0]}" "$COMP_LOG"
    fi
  fi

  echo "[2/3] Compile: SUCCESS"
  if grep -Eq "warning|Warning" "$COMP_LOG"; then
    echo "[2/3] Compile: WARNINGS detected (see $COMP_LOG)"
  fi
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "--- iverilog (tail) ---"
    tail -n 15 "$COMP_LOG"
    echo "------------------------"
  fi

  echo ""
  echo "[3/3] Run simulation"
  if ! vvp build/sim 2>&1 | tee "$SIM_LOG"; then
    echo "[3/3] Simulation: FAILED, attempting auto-fix..."
    if ! "$PYTHON_BIN" runner/sim_fix.py --tb build/tb_gen.sv --filelist "$FL" --spec "$SPEC" \
        --failed-sim-log "$SIM_LOG" --max-iters "$MAX_ITERS" 2>&1 | tee "$SIM_FIX_LOG"; then
      if test_retryable_failure "$SIM_FIX_LOG" "$SIM_LOG" && [[ "$attempt" -lt "$MAX_RETRIES" ]]; then
        echo "[3/3] Simulation: RETRYING due to transient error"
        continue
      fi
      fail_and_exit "Simulation (auto-fix failed)" "${PIPESTATUS[0]}" "$SIM_FIX_LOG"
    fi
  fi

  echo "[3/3] Simulation finished (exit 0)"
  echo ""
  echo "=== SUMMARY ==="
  if grep -Eq "RESULT:[[:space:]]*PASS|TEST_PASS" "$SIM_LOG" "$SIM_FIX_LOG" 2>/dev/null; then
    if grep -Eq "RESULT:[[:space:]]*FAIL|TEST_FAIL|\\$fatal" "$SIM_LOG" "$SIM_FIX_LOG" 2>/dev/null; then
      echo "RESULT: Both PASS and FAIL markers found; check $SIM_LOG."
    else
      echo "RESULT: PASS marker detected in simulation output."
    fi
  elif grep -Eq "RESULT:[[:space:]]*FAIL|TEST_FAIL|\\$fatal" "$SIM_LOG" "$SIM_FIX_LOG" 2>/dev/null; then
    echo "RESULT: FAIL marker detected in simulation output."
  else
    echo "RESULT: No explicit PASS/FAIL markers found in sim output."
  fi
  echo "Logs:"
  echo "  TB generation: $GEN_LOG"
  echo "  Compile:       $COMP_LOG"
  echo "  Compile-fix:   $FIX_LOG"
  echo "  Simulation:    $SIM_LOG"
  echo "  Sim-fix:       $SIM_FIX_LOG"
  echo "================"
  exit 0
done

exit 1
