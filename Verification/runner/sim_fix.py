#!/usr/bin/env python3
"""
sim_fix.py — post-simulation triage and TB auto-fix loop.

If simulation fails, triage TB vs DUT using LLM. If TB, apply minimal edits
with a fixer + checker, then recompile and simulate. Repeat until DUT is blamed
or sim passes.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from verification import TamusAdapter, OpenAIAdapter, AnthropicAdapter, EchoAdapter  # type: ignore
from generate_tb import icarus_fixups  # type: ignore
from compile_fix import compile_fix_loop  # type: ignore


def read(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        # Some Windows tools emit UTF-16 or mixed-encoding logs.
        return p.read_text(encoding="utf-8", errors="replace")


def write(p: Path, s: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(s, encoding="utf-8")


def run_iverilog(filelist: Path, out_exe: Path) -> Tuple[int, str]:
    cmd = ["iverilog", "-g2012", "-f", str(filelist), "-o", str(out_exe)]
    print(f"[sim_fix] compile: {' '.join(cmd)}")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    output = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, output


def run_vvp(exe: Path) -> Tuple[int, str]:
    cmd = ["vvp", str(exe)]
    print(f"[sim_fix] simulate: {' '.join(cmd)}")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    output = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, output


def sim_failed(output: str, exit_code: int) -> bool:
    if exit_code != 0:
        return True
    if re.search(r"RESULT:\s*FAIL", output) or "$fatal" in output:
        return True
    return False


def provider_from_env():
    provider = os.getenv("LLM_PROVIDER", "echo").lower()
    model = os.getenv("LLM_MODEL", "protected.gpt-5")
    if provider == "tamu":
        return TamusAdapter(model=model)
    if provider == "openai":
        return OpenAIAdapter(model=model)
    if provider == "anthropic":
        return AnthropicAdapter(model=model)
    return EchoAdapter(model="echo")


def parse_filelist(filelist: Path) -> List[Path]:
    root = filelist.parent.parent  # build/.. == Verification
    files: List[Path] = []
    for ln in read(filelist).splitlines():
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("+incdir+"):
            continue
        p = (root / s).resolve()
        files.append(p)
    return files


def load_sources(paths: List[Path], max_chars: int = 20000) -> str:
    chunks: List[str] = []
    total = 0
    for p in paths:
        if not p.exists() or p.suffix.lower() != ".sv":
            continue
        try:
            txt = read(p)
        except Exception:
            continue
        header = f"\n// ---- {p.name} ----\n"
        chunk = header + txt
        if total + len(chunk) > max_chars:
            remain = max_chars - total
            if remain <= 0:
                break
            chunk = chunk[:remain] + "\n// ...(truncated)...\n"
            chunks.append(chunk)
            break
        chunks.append(chunk)
        total += len(chunk)
    return "".join(chunks)


def _safe_json_load(s: str) -> Optional[Dict[str, Any]]:
    try:
        return json.loads(s)
    except Exception:
        return None


def _strip_any_fences(s: str) -> str:
    return re.sub(r"^```(?:json)?\s*|\s*```$", "", s.strip(), flags=re.DOTALL)


def parse_edits(raw: str) -> List[Dict[str, str]]:
    js = _safe_json_load(_strip_any_fences(raw))
    if not js or not isinstance(js, dict):
        return []
    edits = js.get("edits", [])
    if not isinstance(edits, list):
        return []
    out: List[Dict[str, str]] = []
    for e in edits:
        if isinstance(e, dict) and e.get("kind") and isinstance(e.get("kind"), str):
            out.append({k: str(v) for k, v in e.items()})
    return out


def apply_edits(tb: str, edits: List[Dict[str, str]]) -> str:
    out = tb
    for e in edits:
        kind = e.get("kind", "")
        if kind == "replace_once":
            find = e.get("find", "")
            repl = e.get("replace", "")
            if find:
                out = out.replace(find, repl, 1)
        elif kind == "insert_after":
            anchor = e.get("anchor", "")
            insert = e.get("insert", "")
            if anchor and anchor in out:
                out = out.replace(anchor, anchor + insert, 1)
        elif kind == "insert_before":
            anchor = e.get("anchor", "")
            insert = e.get("insert", "")
            if anchor and anchor in out:
                out = out.replace(anchor, insert + anchor, 1)
    return out


TRIAGE_SYSTEM = """\
You are a SystemVerilog verification triage assistant.
Given a DUT, a testbench, a spec, and failing simulation output, decide
whether the failure is more likely due to a BAD TESTBENCH or a BAD DUT.

Return STRICT JSON only:
{
  "verdict": "TB" | "DUT" | "INCONCLUSIVE",
  "reasons": ["short reason", ...]
}
"""

FIX_SYSTEM = """\
You are a SystemVerilog testbench fixer for Icarus Verilog (-g2012).
Propose minimal edits to the TESTBENCH ONLY to fix the simulation failures.

Constraints:
- Do not touch DUT sources or change module ports.
- Keep edits localized and safe; avoid overfitting.
- Respect Icarus quirks: decls before statements; no 'final'; avoid 'break'.
- NO code fences. Return STRICT JSON only.
- JSON schema:
  {
    "edits": [
      { "kind": "replace_once", "find": "exact string", "replace": "replacement" } |
      { "kind": "insert_after", "anchor": "exact string to locate", "insert": "string to insert" } |
      { "kind": "insert_before", "anchor": "exact string to locate", "insert": "string to insert" }
    ]
  }
If you cannot fix, return { "edits": [] }.
"""

CHECK_SYSTEM = """\
You are a SystemVerilog testbench checker. Approve or reject the proposed
testbench changes before re-running compilation/simulation.

Return STRICT JSON only:
{
  "verdict": "APPROVE" | "REJECT",
  "reasons": ["short reason", ...]
}
"""


def llm_triage(provider, dut_text: str, tb_text: str, spec_text: str, sim_out: str, failed_log: str) -> Dict[str, Any]:
    user = (
        "SPEC:\n-----\n" + spec_text.strip() + "\n-----\n\n"
        "DUT:\n-----\n" + dut_text.strip() + "\n-----\n\n"
        "TESTBENCH:\n-----\n" + tb_text.strip() + "\n-----\n\n"
        "FAILED SIM LOG (original):\n-----\n" + failed_log.strip() + "\n-----\n\n"
        "CURRENT SIM OUTPUT:\n-----\n" + sim_out.strip() + "\n-----\n"
    )
    raw = provider.complete(TRIAGE_SYSTEM, user)  # type: ignore
    if not isinstance(raw, str):
        return {"verdict": "INCONCLUSIVE", "reasons": ["non-string LLM output"]}
    js = _safe_json_load(_strip_any_fences(raw)) or {}
    verdict = str(js.get("verdict", "INCONCLUSIVE")).upper()
    reasons = js.get("reasons", [])
    if verdict not in ("TB", "DUT", "INCONCLUSIVE"):
        verdict = "INCONCLUSIVE"
    if not isinstance(reasons, list):
        reasons = []
    return {"verdict": verdict, "reasons": reasons}


def llm_fix(provider, tb_text: str, spec_text: str, sim_out: str) -> List[Dict[str, str]]:
    user = (
        "SPEC:\n-----\n" + spec_text.strip() + "\n-----\n\n"
        "TESTBENCH:\n-----\n" + tb_text.strip() + "\n-----\n\n"
        "SIM OUTPUT:\n-----\n" + sim_out.strip() + "\n-----\n"
    )
    raw = provider.complete(FIX_SYSTEM, user)  # type: ignore
    if not isinstance(raw, str):
        return []
    return parse_edits(raw)


def llm_check(provider, tb_text: str, spec_text: str, sim_out: str) -> Dict[str, Any]:
    user = (
        "SPEC:\n-----\n" + spec_text.strip() + "\n-----\n\n"
        "TESTBENCH:\n-----\n" + tb_text.strip() + "\n-----\n\n"
        "SIM OUTPUT:\n-----\n" + sim_out.strip() + "\n-----\n"
    )
    raw = provider.complete(CHECK_SYSTEM, user)  # type: ignore
    if not isinstance(raw, str):
        return {"verdict": "REJECT", "reasons": ["non-string LLM output"]}
    js = _safe_json_load(_strip_any_fences(raw)) or {}
    verdict = str(js.get("verdict", "REJECT")).upper()
    reasons = js.get("reasons", [])
    if verdict not in ("APPROVE", "REJECT"):
        verdict = "REJECT"
    if not isinstance(reasons, list):
        reasons = []
    return {"verdict": verdict, "reasons": reasons}


def sim_fix_loop(tb_path: Path, filelist: Path, spec_path: Path, failed_sim_log: Optional[Path],
                 max_iters: int) -> Tuple[bool, str]:
    provider = provider_from_env()
    spec_text = read(spec_path)

    fl_files = parse_filelist(filelist)
    dut_files = [p for p in fl_files if p.name not in {"tb_gen.sv", "auto_stub_dut.sv", "stub_dut.sv"}]
    dut_text = load_sources(dut_files)

    failed_log_text = read(failed_sim_log) if (failed_sim_log and failed_sim_log.exists()) else ""

    last_checker_reasons: List[str] = []
    for i in range(1, max_iters + 1):
        print(f"[sim_fix] ===== Iteration {i}/{max_iters} =====")

        # compile (with auto compile-fix if needed)
        exe_path = filelist.parent / "sim"
        comp_code, comp_out = run_iverilog(filelist, exe_path)
        if comp_code != 0:
            print("[sim_fix] compile failed; attempting compile-fix loop...")
            ok, msg = compile_fix_loop(tb_path, filelist, max_iters=3)
            print(msg)
            if not ok:
                return False, "[sim_fix] compile-fix failed; stopping."
            comp_code, comp_out = run_iverilog(filelist, exe_path)
            if comp_code != 0:
                return False, "[sim_fix] compile still failing after compile-fix."

        sim_code, sim_out = run_vvp(exe_path)
        if not sim_failed(sim_out, sim_code):
            return True, "[sim_fix] simulation passed after fixes."

        tb_text = read(tb_path)
        triage = llm_triage(provider, dut_text, tb_text, spec_text, sim_out, failed_log_text)
        print(f"[sim_fix] triage verdict={triage.get('verdict')} reasons={'; '.join(triage.get('reasons', [])) or '(none)'}")

        if triage.get("verdict") == "DUT":
            return False, "[sim_fix] triage indicates DUT is bad; stopping auto-fix."

        # Feed back prior checker rejections to the fixer for better next edits.
        if last_checker_reasons:
            sim_out_with_feedback = (
                sim_out
                + "\n\n[CHECKER_REJECT_REASONS]\n"
                + "\n".join(f"- {r}" for r in last_checker_reasons)
            )
        else:
            sim_out_with_feedback = sim_out

        edits = llm_fix(provider, tb_text, spec_text, sim_out_with_feedback)
        if not edits:
            return False, "[sim_fix] LLM returned no TB edits; stopping."

        tb_new = apply_edits(tb_text, edits)
        tb_new = icarus_fixups(tb_new)

        check = llm_check(provider, tb_new, spec_text, sim_out)
        print(f"[sim_fix] checker verdict={check.get('verdict')} reasons={'; '.join(check.get('reasons', [])) or '(none)'}")
        if check.get("verdict") != "APPROVE":
            last_checker_reasons = list(check.get("reasons", [])) if isinstance(check.get("reasons", []), list) else []
            print("[sim_fix] checker rejected TB edits; retrying with feedback.")
            # Do not write rejected TB; continue to next iteration.
            continue

        write(tb_path, tb_new)
        print(f"[sim_fix] applied {len(edits)} edits to TB.")
        last_checker_reasons = []

    return False, "[sim_fix] max iterations reached; stopping."


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tb", required=True, help="Path to generated tb_gen.sv")
    ap.add_argument("--filelist", required=True, help="Path to iverilog filelist")
    ap.add_argument("--spec", required=True, help="Path to spec.json")
    ap.add_argument("--failed-sim-log", default="", help="Path to failed sim log (optional)")
    ap.add_argument("--max-iters", type=int, default=int(os.getenv("TB_SIM_FIX_MAX_ITERS", "5")))
    args = ap.parse_args()

    tb_path = Path(args.tb).resolve()
    fl_path = Path(args.filelist).resolve()
    spec_path = Path(args.spec).resolve()
    failed_log = Path(args.failed_sim_log).resolve() if args.failed_sim_log else None

    if not tb_path.exists():
        raise SystemExit(f"TB not found: {tb_path}")
    if not fl_path.exists():
        raise SystemExit(f"Filelist not found: {fl_path}")
    if not spec_path.exists():
        raise SystemExit(f"Spec not found: {spec_path}")

    ok, msg = sim_fix_loop(tb_path, fl_path, spec_path, failed_log, args.max_iters)
    print(msg)
    raise SystemExit(0 if ok else 2)


if __name__ == "__main__":
    main()
