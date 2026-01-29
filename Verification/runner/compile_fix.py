#!/usr/bin/env python3
"""
compile_fix.py — post-compile error fixer for generated testbenches.

Runs iverilog against a filelist; if compile errors appear in the testbench,
asks an LLM for minimal edits and applies them, then retries up to max iters.
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


ERROR_FILE_RE = re.compile(r"(?P<file>\S+\.sv):(?P<line>\d+):")


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def write(p: Path, s: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(s, encoding="utf-8")


def run_iverilog(filelist: Path) -> Tuple[int, str]:
    cmd = ["iverilog", "-g2012", "-f", str(filelist), "-tnull"]
    print(f"[compile_fix] compile: {' '.join(cmd)}")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    output = ""
    if proc.stdout:
        output += proc.stdout
    if proc.stderr:
        output += proc.stderr
    return proc.returncode, output


def extract_error_files(output: str) -> List[str]:
    files: List[str] = []
    for line in output.splitlines():
        if "error:" not in line and "syntax error" not in line:
            continue
        m = ERROR_FILE_RE.search(line)
        if m:
            files.append(Path(m.group("file")).name)
    # fallback: if output mentions tb_gen.sv anywhere
    if not files and "tb_gen.sv" in output:
        files.append("tb_gen.sv")
    return sorted(set(files))


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


COMPILE_FIX_SYSTEM = """\
You are an expert SystemVerilog compile-fix assistant for Icarus Verilog (-g2012).
Goal: propose minimal edits to the testbench ONLY to fix the compile errors below.

Constraints:
- Do not touch DUT sources or change module ports.
- Keep edits localized and safe.
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


def llm_fix(tb_text: str, compile_out: str, provider) -> List[Dict[str, str]]:
    user = (
        "Compile output (iverilog):\n"
        "-----\n"
        f"{compile_out.strip()}\n"
        "-----\n\n"
        "Testbench source:\n"
        "-----\n"
        f"{tb_text}\n"
        "-----\n"
    )
    if hasattr(provider, "complete"):
        raw = provider.complete(COMPILE_FIX_SYSTEM, user)  # type: ignore
    else:
        raise RuntimeError("Provider does not support complete().")
    if not isinstance(raw, str):
        return []
    return parse_edits(raw)


def compile_fix_loop(tb_path: Path, filelist: Path, max_iters: int) -> Tuple[bool, str]:
    provider = provider_from_env()
    allowed_files = {"tb_gen.sv", "auto_stub_dut.sv", "stub_dut.sv"}
    for i in range(1, max_iters + 1):
        code, out = run_iverilog(filelist)
        if code == 0:
            return True, f"[compile_fix] compile passed on iter {i}."

        error_files = extract_error_files(out)
        if error_files and any(f not in allowed_files for f in error_files):
            return False, (
                "[compile_fix] compile errors reference non-testbench files: "
                + ", ".join(error_files)
            )

        tb_text = read(tb_path)
        edits = llm_fix(tb_text, out, provider)
        if not edits:
            return False, "[compile_fix] LLM returned no edits; giving up."

        tb_text = apply_edits(tb_text, edits)
        tb_text = icarus_fixups(tb_text)
        write(tb_path, tb_text)
        print(f"[compile_fix] applied {len(edits)} edits (iter {i}).")

    return False, f"[compile_fix] max iterations reached ({max_iters})."


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tb", required=True, help="Path to generated tb_gen.sv")
    ap.add_argument("--filelist", required=True, help="Path to iverilog filelist")
    ap.add_argument("--max-iters", type=int, default=int(os.getenv("TB_COMPILE_FIX_MAX_ITERS", "5")))
    args = ap.parse_args()

    tb_path = Path(args.tb).resolve()
    fl_path = Path(args.filelist).resolve()

    if not tb_path.exists():
        raise SystemExit(f"TB not found: {tb_path}")
    if not fl_path.exists():
        raise SystemExit(f"Filelist not found: {fl_path}")

    ok, msg = compile_fix_loop(tb_path, fl_path, args.max_iters)
    print(msg)
    raise SystemExit(0 if ok else 2)


if __name__ == "__main__":
    main()
