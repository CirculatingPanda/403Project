#!/usr/bin/env python3
"""
orchestrator.py - Overarching CLI for Generation/Verification and future subsystems.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional


ROOT = Path(__file__).resolve().parent
GEN_DIR = ROOT / "Generationv2"
VER_DIR = ROOT / "Verification"
FE_DIR = ROOT / "Front End"
GEN_SPECS = GEN_DIR / "specs"
VER_SPECS = VER_DIR / "specs"
DUT_DIR = VER_DIR / "DUT"
GEN_OUT = GEN_DIR / "output"
VER_LOGS = VER_DIR / "logs"


@dataclass
class Subsystem:
    name: str
    cmd: List[str]
    cwd: Path
    env: Optional[Dict[str, str]] = None


def _which_shell() -> str:
    if shutil.which("pwsh"):
        return "pwsh"
    return "powershell"


def _load_config(path: Optional[str]) -> Dict[str, Subsystem]:
    subsystems: Dict[str, Subsystem] = {}

    # Default built-ins
    subsystems["verification"] = Subsystem(
        name="verification",
        cmd=[_which_shell(), "-File", str(VER_DIR / "run.ps1")],
        cwd=VER_DIR,
    )
    subsystems["generation"] = Subsystem(
        name="generation",
        cmd=["python", str(GEN_DIR / "mc_generator_v2.py")],
        cwd=GEN_DIR,
    )

    if not path:
        return subsystems

    cfg_path = Path(path).resolve()
    if not cfg_path.exists():
        raise SystemExit(f"Config not found: {cfg_path}")
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    for name, entry in cfg.get("subsystems", {}).items():
        cmd = entry.get("cmd", [])
        cwd = entry.get("cwd", str(ROOT))
        env = entry.get("env", None)
        if isinstance(cmd, str):
            cmd = cmd.split()
        if not isinstance(cmd, list) or not cmd:
            continue
        subsystems[name] = Subsystem(
            name=name,
            cmd=[str(c) for c in cmd],
            cwd=Path(cwd).resolve(),
            env=env if isinstance(env, dict) else None,
        )
    return subsystems


def _run_cmd(subsys: Subsystem, extra_args: List[str], dry_run: bool) -> int:
    cmd = list(subsys.cmd) + extra_args
    if dry_run:
        print("[orchestrator] dry-run:", " ".join(cmd))
        return 0
    env = os.environ.copy()
    if subsys.env:
        env.update({k: str(v) for k, v in subsys.env.items()})
    print("[orchestrator] running:", " ".join(cmd))
    proc = subprocess.run(cmd, cwd=str(subsys.cwd), env=env)
    return proc.returncode


def _status(subsystems: Dict[str, Subsystem]) -> int:
    print("Subsystems:")
    for name, ss in subsystems.items():
        print(f"  - {name}: cmd={ss.cmd} cwd={ss.cwd}")
    print("")
    print("Paths:")
    print(f"  ROOT: {ROOT}")
    print(f"  Generation: {GEN_DIR} ({'ok' if GEN_DIR.exists() else 'missing'})")
    print(f"  Verification: {VER_DIR} ({'ok' if VER_DIR.exists() else 'missing'})")
    print(f"  Front End: {FE_DIR} ({'ok' if FE_DIR.exists() else 'missing'})")
    print(f"  Gen specs: {GEN_SPECS}")
    print(f"  Ver specs: {VER_SPECS}")
    print(f"  DUT dir: {DUT_DIR}")
    return 0


def _verify(subsystems: Dict[str, Subsystem], args: argparse.Namespace) -> int:
    ss = subsystems["verification"]
    extra: List[str] = []
    if args.spec:
        extra += ["-Spec", args.spec]
    else:
        latest = _latest_json(VER_SPECS)
        if latest:
            extra += ["-Spec", str(latest)]
    if args.max_iters is not None:
        extra += ["-MaxIters", str(args.max_iters)]
    if args.log_dir:
        extra += ["-LogDir", args.log_dir]
    if args.verbose:
        extra += ["-Verbose"]
    if args.clean_only:
        extra += ["-CleanOnly"]
    if args.passthrough:
        extra += args.passthrough
    return _run_cmd(ss, extra, args.dry_run)


def _generation(subsystems: Dict[str, Subsystem], args: argparse.Namespace) -> int:
    ss = subsystems["generation"]
    extra: List[str] = []
    if args.spec:
        extra += ["-s", args.spec]
    else:
        latest = _latest_json(GEN_SPECS)
        if latest:
            extra += ["-s", str(latest)]
    if args.output:
        extra += ["-o", args.output]
    if args.passthrough:
        extra += args.passthrough
    rc = _run_cmd(ss, extra, args.dry_run)
    if rc == 0 and not args.dry_run:
        _sync_gen_output_to_dut()
    return rc


def _latest_json(front_end_dir: Path) -> Optional[Path]:
    if not front_end_dir.exists():
        return None
    candidates = []
    for p in front_end_dir.glob("*.json"):
        if p.name == "spec_registry.json":
            continue
        try:
            candidates.append((p.stat().st_mtime, p))
        except Exception:
            continue
    if not candidates:
        return None
    candidates.sort(key=lambda t: t[0], reverse=True)
    return candidates[0][1]


def _copy_spec_to_targets(spec_path: Path) -> List[Path]:
    targets: List[Path] = []
    GEN_SPECS.mkdir(parents=True, exist_ok=True)
    VER_SPECS.mkdir(parents=True, exist_ok=True)
    gen_out = GEN_SPECS / spec_path.name
    ver_out = VER_SPECS / spec_path.name
    shutil.copy2(spec_path, gen_out)
    shutil.copy2(spec_path, ver_out)
    targets.extend([gen_out, ver_out])
    return targets


def _chat(subsystems: Dict[str, Subsystem], args: argparse.Namespace) -> int:
    chat_py = FE_DIR / "chat.py"
    if not chat_py.exists():
        raise SystemExit(f"Front End chat.py not found: {chat_py}")
    cmd = ["python", str(chat_py)]
    if args.dry_run:
        print("[orchestrator] dry-run:", " ".join(cmd))
        return 0
    print("[orchestrator] launching front end chat...")
    proc = subprocess.run(cmd, cwd=str(FE_DIR))
    if proc.returncode != 0:
        return proc.returncode

    # After chat exits, pick the latest JSON spec and copy to targets.
    spec = _latest_json(FE_DIR)
    if not spec:
        print("[orchestrator] No spec JSON found in Front End directory.")
        return 2
    targets = _copy_spec_to_targets(spec)
    print("[orchestrator] Copied spec to:")
    for t in targets:
        print(f"  - {t}")
    return 0


def _sync_gen_output_to_dut() -> None:
    if not GEN_OUT.exists():
        print("[orchestrator] No generation output directory found.")
        return
    DUT_DIR.mkdir(parents=True, exist_ok=True)
    copied = 0
    for p in GEN_OUT.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix.lower() not in (".sv", ".v", ".svh"):
            continue
        dst = DUT_DIR / p.name
        shutil.copy2(p, dst)
        copied += 1
    print(f"[orchestrator] Copied {copied} RTL files to DUT.")


def _clear_specs_and_dut() -> int:
    gen_spec_count = 0
    ver_spec_count = 0
    dut_count = 0
    out_count = 0
    if GEN_SPECS.exists():
        for p in GEN_SPECS.rglob("*"):
            if p.is_file():
                try:
                    p.unlink()
                    gen_spec_count += 1
                except Exception:
                    pass
    if VER_SPECS.exists():
        for p in VER_SPECS.rglob("*"):
            if p.is_file():
                try:
                    p.unlink()
                    ver_spec_count += 1
                except Exception:
                    pass
    if DUT_DIR.exists():
        for p in DUT_DIR.rglob("*"):
            if p.is_file():
                try:
                    p.unlink()
                    dut_count += 1
                except Exception:
                    pass
    if GEN_OUT.exists():
        for p in GEN_OUT.rglob("*"):
            if p.is_file():
                try:
                    p.unlink()
                    out_count += 1
                except Exception:
                    pass
        # remove empty subdirs
        for p in sorted(GEN_OUT.rglob("*"), reverse=True):
            if p.is_dir():
                try:
                    p.rmdir()
                except Exception:
                    pass
    log_count = 0
    if VER_LOGS.exists():
        for p in VER_LOGS.rglob("*"):
            if p.is_file():
                try:
                    p.unlink()
                    log_count += 1
                except Exception:
                    pass
        for p in sorted(VER_LOGS.rglob("*"), reverse=True):
            if p.is_dir():
                try:
                    p.rmdir()
                except Exception:
                    pass
    print(f"[orchestrator] Cleared specs: gen={gen_spec_count}, ver={ver_spec_count}; "
          f"DUT files={dut_count}; gen output files={out_count}; logs={log_count}.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Overarching project orchestrator.")
    ap.add_argument("--config", default="", help="Optional JSON config for subsystems")
    ap.add_argument("--dry-run", action="store_true", help="Print commands without running")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub_status = sub.add_parser("status", help="Show subsystem wiring")
    sub_status.set_defaults(func=lambda subsystems, args: _status(subsystems))

    sub_ver = sub.add_parser("verify", help="Run verification flow")
    sub_ver.add_argument("--spec", default="", help="Spec file path")
    sub_ver.add_argument("--max-iters", type=int, default=None, help="Max iterations for LLM loops")
    sub_ver.add_argument("--log-dir", default="", help="Override log directory")
    sub_ver.add_argument("--verbose", action="store_true", help="Verbose verification output")
    sub_ver.add_argument("--clean-only", action="store_true", help="Only clean artifacts and exit")
    sub_ver.add_argument("passthrough", nargs=argparse.REMAINDER, help="Extra args for run.ps1")
    sub_ver.set_defaults(func=_verify)

    sub_gen = sub.add_parser("generate", help="Run generation flow")
    sub_gen.add_argument("--spec", default="", help="Spec file path (defaults to latest in Generationv2/specs)")
    sub_gen.add_argument("--output", default="", help="Output directory for generator")
    sub_gen.add_argument("passthrough", nargs=argparse.REMAINDER, help="Args forwarded to generator")
    sub_gen.set_defaults(func=_generation)

    sub_chat = sub.add_parser("chat", help="Launch front-end chatbot and sync spec JSON")
    sub_chat.set_defaults(func=_chat)

    sub_clear = sub.add_parser("clear", help="Clear specs and DUT files")
    sub_clear.set_defaults(func=lambda subsystems, args: _clear_specs_and_dut())

    args = ap.parse_args()
    subsystems = _load_config(args.config or None)
    if args.cmd not in subsystems and args.cmd not in ("status", "verify", "generate", "chat", "clear"):
        raise SystemExit(f"Unknown subsystem: {args.cmd}")

    return args.func(subsystems, args)


if __name__ == "__main__":
    raise SystemExit(main())
