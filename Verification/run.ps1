Param(
  [string]$Spec = "specs\sram_controller_2025-11-03_08-29-11.json",
  [int]$MaxIters = [int](@($env:TB_CHECKER_MAX_ITERS, 10) | Where-Object { $_ -ne $null } | Select-Object -First 1),
  [string]$LogDir = "logs",
  [switch]$Verbose,
  [switch]$CleanOnly
)

# ------------------------------
# Setup
# ------------------------------
Write-Host "=== TB RUNNER ==="
Write-Host "Spec:        $Spec"
Write-Host "Max iters:   $MaxIters"
Write-Host "Logs:        $LogDir"
Write-Host ""

if (-not $env:LLM_PROVIDER) {
  $env:LLM_PROVIDER = "tamu"
}
$env:PYTHONUNBUFFERED = "1"

# Ensure dirs exist
New-Item -ItemType Directory -Force -Path build | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$genLog  = Join-Path $LogDir "01_generate_tb.log"
$compLog = Join-Path $LogDir "02_compile.log"
$fixLog  = Join-Path $LogDir "02_compile_fix.log"
$simLog  = Join-Path $LogDir "03_sim.log"
$simFixLog = Join-Path $LogDir "03_sim_fix.log"

function Fail-And-Exit {
  param(
    [string]$Stage,
    [int]$Code,
    [string]$LogPath
  )
  Write-Host ""
  Write-Host "[$Stage] FAILED (exit code $Code)" -ForegroundColor Red
  if (Test-Path $LogPath) {
    Write-Host "See log: $LogPath" -ForegroundColor Yellow
  }
  exit $Code
}

function Clear-RunArtifacts {
  param(
    [string]$LogDir = "logs"
  )
  $generatedLogs = @(
    "01_generate_tb.log",
    "02_compile.log",
    "02_compile_fix.log",
    "03_sim.log",
    "03_sim_fix.log"
  )
  foreach ($log in $generatedLogs) {
    $path = Join-Path $LogDir $log
    if (Test-Path $path) {
      Remove-Item -Force $path
    }
  }

  $generatedBuildFiles = @(
    "build\\tb_gen.sv",
    "build\\tb_gen_syntax.sv",
    "build\\auto_stub_dut.sv",
    "build\\filelist.f",
    "build\\sim"
  )
  foreach ($file in $generatedBuildFiles) {
    if (Test-Path $file) {
      Remove-Item -Force $file
    }
  }
}

if ($CleanOnly) {
  Clear-RunArtifacts -LogDir $LogDir
  Write-Host "Cleanup complete for LogDir '$LogDir'." -ForegroundColor Green
  exit 0
}

# ------------------------------
# 1/3 Generate TB
# ------------------------------
Write-Host "[1/3] Generate TB from $Spec"

# Build args for generate_tb.py
$genArgs = @(
  "--spec", $Spec,
  "--out", "build\tb_gen.sv",
  "--max-iters", $MaxIters
  # NOTE: We let generate_tb.py pick engineer/checker models by itself.
  # If you later want to override:
  # "--engineer-model", "protected.gpt-5",
  # "--checker-model",  "protected.gpt-5"
)

# If you want to be explicit about DUT dir, uncomment this:
# $dutDir = (Resolve-Path ".\DUT").Path
# $genArgs += @("--dut-dir", $dutDir)

$genOut = python runner\generate_tb.py @genArgs 2>&1 | Tee-Object -FilePath $genLog
$genExit = $LASTEXITCODE

if ($genExit -ne 0) {
  Fail-And-Exit "Generate TB" $genExit $genLog
}

Write-Host "[1/3] Generate TB: SUCCESS" -ForegroundColor Green
if ($Verbose) {
  Write-Host "--- generate_tb.py (tail) ---" -ForegroundColor DarkCyan
  $genOut | Select-Object -Last 15
  Write-Host "--------------------------------"
}

# ------------------------------
# 2/3 Compile
# ------------------------------
Write-Host ""
Write-Host "[2/3] Compile"
$fl = "build\filelist.f"
if (-not (Test-Path $fl)) {
  Write-Host "ERROR: filelist '$fl' not found. Generation must have failed." -ForegroundColor Red
  Fail-And-Exit "Compile (missing filelist)" 2 $genLog
}

$compOut = & iverilog -g2012 -f $fl -o build\sim 2>&1 | Tee-Object -FilePath $compLog
$compExit = $LASTEXITCODE

if ($compExit -ne 0) {
  Write-Host "[2/3] Compile: FAILED, attempting auto-fix..." -ForegroundColor Yellow
  $fixOut = python runner\compile_fix.py --tb build\tb_gen.sv --filelist $fl --max-iters $MaxIters 2>&1 | Tee-Object -FilePath $fixLog
  $fixExit = $LASTEXITCODE

  if ($fixExit -ne 0) {
    Fail-And-Exit "Compile (auto-fix failed)" $compExit $fixLog
  }

  # Re-compile after fixes
  $compOut = & iverilog -g2012 -f $fl -o build\sim 2>&1 | Tee-Object -FilePath $compLog
  $compExit = $LASTEXITCODE
  if ($compExit -ne 0) {
    Fail-And-Exit "Compile (after auto-fix)" $compExit $compLog
  }
}

Write-Host "[2/3] Compile: SUCCESS" -ForegroundColor Green

if ($compOut -match "warning" -or $compOut -match "Warning") {
  Write-Host "[2/3] Compile: WARNINGS detected (see $compLog)" -ForegroundColor Yellow
}

if ($Verbose) {
  Write-Host "--- iverilog (tail) ---" -ForegroundColor DarkCyan
  $compOut | Select-Object -Last 15
  Write-Host "------------------------"
}

# ------------------------------
# 3/3 Run simulation
# ------------------------------
Write-Host ""
Write-Host "[3/3] Run simulation"

$simOut = & vvp build\sim 2>&1 | Tee-Object -FilePath $simLog
$simExit = $LASTEXITCODE

if ($simExit -ne 0) {
  Write-Host "[3/3] Simulation: FAILED, attempting auto-fix..." -ForegroundColor Yellow
  $simFixOut = python runner\sim_fix.py --tb build\tb_gen.sv --filelist $fl --spec $Spec --failed-sim-log $simLog --max-iters $MaxIters 2>&1 | Tee-Object -FilePath $simFixLog
  $simFixExit = $LASTEXITCODE
  if ($simFixExit -ne 0) {
    Fail-And-Exit "Simulation (auto-fix failed)" $simExit $simFixLog
  }
  $simExit = 0
  $simOut = $simFixOut
}

Write-Host "[3/3] Simulation finished (exit 0)" -ForegroundColor Green

# ------------------------------
# Post-run summary
# ------------------------------
$passed = $false
$failed = $false

if ($simOut -match "RESULT:\s*PASS" -or $simOut -match "TEST_PASS") { $passed = $true }
if ($simOut -match "RESULT:\s*FAIL" -or $simOut -match "TEST_FAIL" -or $simOut -match "\$fatal") { $failed = $true }

Write-Host ""
Write-Host "=== SUMMARY ==="
if ($passed -and -not $failed) {
  Write-Host "RESULT: PASS marker detected in simulation output." -ForegroundColor Green
} elseif ($failed -and -not $passed) {
  Write-Host "RESULT: FAIL marker detected in simulation output." -ForegroundColor Red
} elseif ($failed -and $passed) {
  Write-Host "RESULT: Both PASS and FAIL markers found; check $simLog." -ForegroundColor Yellow
} else {
  Write-Host "RESULT: No explicit PASS/FAIL markers found in sim output." -ForegroundColor Yellow
}

Write-Host "Logs:"
Write-Host "  TB generation: $genLog"
Write-Host "  Compile:       $compLog"
Write-Host "  Compile-fix:   $fixLog"
Write-Host "  Simulation:    $simLog"
Write-Host "  Sim-fix:       $simFixLog"
Write-Host "================"

exit $simExit
