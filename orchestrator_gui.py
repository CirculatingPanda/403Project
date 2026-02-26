#!/usr/bin/env python3
"""
orchestrator_gui.py - GUI for orchestrator phases and future extensions.
Requires PySide6 (already used by Front End).
"""
from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

from PySide6.QtCore import Qt, QThread, Signal
from PySide6.QtWidgets import (
    QApplication,
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QProgressBar,
    QTextEdit,
    QFileDialog,
    QGroupBox,
    QCheckBox,
)

ROOT = Path(__file__).resolve().parent
PY = str(Path(__file__).resolve().parent / ".venv" / "Scripts" / "python.exe")
if not Path(PY).exists():
    PY = "python"
FE_DIR = ROOT / "Front End"
GEN_DIR = ROOT / "Generationv2"
VER_DIR = ROOT / "Verification"


@dataclass
class Phase:
    name: str
    cmd: List[str]
    cwd: Path


PHASES = [
    Phase("Front End Chat", [PY, str(FE_DIR / "chat.py")], FE_DIR),
    Phase("Generation", [PY, str(GEN_DIR / "mc_generator_v2.py")], GEN_DIR),
    Phase("Verification", ["pwsh", "-File", str(VER_DIR / "run.ps1")], VER_DIR),
]


def _latest_json(dir_path: Path) -> Optional[Path]:
    if not dir_path.exists():
        return None
    candidates = []
    for p in dir_path.glob("*.json"):
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
    gen_specs = GEN_DIR / "specs"
    ver_specs = VER_DIR / "specs"
    gen_specs.mkdir(parents=True, exist_ok=True)
    ver_specs.mkdir(parents=True, exist_ok=True)
    gen_out = gen_specs / spec_path.name
    ver_out = ver_specs / spec_path.name
    gen_out.write_bytes(spec_path.read_bytes())
    ver_out.write_bytes(spec_path.read_bytes())
    return [gen_out, ver_out]


def _sync_gen_output_to_dut(log_fn) -> None:
    out_dir = GEN_DIR / "output"
    dut_dir = VER_DIR / "DUT"
    if not out_dir.exists():
        log_fn("[sync] no generation output directory found")
        return
    dut_dir.mkdir(parents=True, exist_ok=True)
    copied = 0
    for p in out_dir.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix.lower() not in (".sv", ".v", ".svh"):
            continue
        dst = dut_dir / p.name
        dst.write_bytes(p.read_bytes())
        copied += 1
    log_fn(f"[sync] copied {copied} RTL files to DUT")


def _clear_specs_and_dut(log_fn) -> None:
    gen_specs = GEN_DIR / "specs"
    ver_specs = VER_DIR / "specs"
    dut_dir = VER_DIR / "DUT"
    gen_out = GEN_DIR / "output"
    gen_spec_count = 0
    ver_spec_count = 0
    dut_count = 0
    out_count = 0
    if gen_specs.exists():
        for p in gen_specs.rglob("*"):
            if p.is_file():
                try:
                    p.unlink()
                    gen_spec_count += 1
                except Exception:
                    pass
    if ver_specs.exists():
        for p in ver_specs.rglob("*"):
            if p.is_file():
                try:
                    p.unlink()
                    ver_spec_count += 1
                except Exception:
                    pass
    if dut_dir.exists():
        for p in dut_dir.rglob("*"):
            if p.is_file():
                try:
                    p.unlink()
                    dut_count += 1
                except Exception:
                    pass
    if gen_out.exists():
        for p in gen_out.rglob("*"):
            if p.is_file():
                try:
                    p.unlink()
                    out_count += 1
                except Exception:
                    pass
        for p in sorted(gen_out.rglob("*"), reverse=True):
            if p.is_dir():
                try:
                    p.rmdir()
                except Exception:
                    pass
    log_fn(f"[clear] specs: gen={gen_spec_count}, ver={ver_spec_count}; "
           f"DUT files={dut_count}; gen output files={out_count}")


class RunnerThread(QThread):
    log = Signal(str)
    finished_ok = Signal(bool)

    def __init__(self, cmd: List[str], cwd: Path):
        super().__init__()
        self.cmd = cmd
        self.cwd = cwd

    def run(self) -> None:
        try:
            self.log.emit(f"[run] {' '.join(self.cmd)}")
            proc = subprocess.run(self.cmd, cwd=str(self.cwd))
            self.finished_ok.emit(proc.returncode == 0)
        except Exception as e:
            self.log.emit(f"[error] {e}")
            self.finished_ok.emit(False)


class OrchestratorGUI(QWidget):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("ECEN403 Orchestrator")
        self.resize(900, 600)

        self.progress = QProgressBar()
        self.progress.setRange(0, 100)
        self.progress.setValue(0)

        self.log = QTextEdit()
        self.log.setReadOnly(True)

        self.btn_chat = QPushButton("Run Front End Chat")
        self.btn_gen = QPushButton("Run Generation")
        self.btn_ver = QPushButton("Run Verification")

        self.chk_skip_gen = QCheckBox("Skip generation (use provided RTL)")
        self.btn_upload_rtl = QPushButton("Upload existing RTL (future)")
        self.chk_clear = QCheckBox("Clear specs + DUT before run")

        self.btn_run_all = QPushButton("Run Full Pipeline")

        self.btn_chat.clicked.connect(lambda: self.run_phase(0))
        self.btn_gen.clicked.connect(lambda: self.run_phase(1))
        self.btn_ver.clicked.connect(lambda: self.run_phase(2))
        self.btn_run_all.clicked.connect(self.run_all)
        self.btn_upload_rtl.clicked.connect(self.upload_rtl)

        layout = QVBoxLayout()
        layout.addWidget(QLabel("Pipeline progress"))
        layout.addWidget(self.progress)

        box = QGroupBox("Controls")
        box_layout = QHBoxLayout()
        box_layout.addWidget(self.btn_chat)
        box_layout.addWidget(self.btn_gen)
        box_layout.addWidget(self.btn_ver)
        box_layout.addWidget(self.btn_run_all)
        box.setLayout(box_layout)
        layout.addWidget(box)

        options = QGroupBox("Options")
        opt_layout = QHBoxLayout()
        opt_layout.addWidget(self.chk_skip_gen)
        opt_layout.addWidget(self.btn_upload_rtl)
        opt_layout.addWidget(self.chk_clear)
        options.setLayout(opt_layout)
        layout.addWidget(options)

        layout.addWidget(QLabel("Log"))
        layout.addWidget(self.log)
        self.setLayout(layout)

        self._current_thread: Optional[RunnerThread] = None
        self._phase_index = 0
        self._pipeline = []
        self._latest_spec: Optional[Path] = None

    def log_line(self, txt: str) -> None:
        self.log.append(txt)

    def set_progress(self, idx: int, total: int) -> None:
        if total <= 0:
            self.progress.setValue(0)
            return
        self.progress.setValue(int(100 * idx / total))

    def run_phase(self, phase_idx: int) -> None:
        phase = PHASES[phase_idx]
        cmd = list(phase.cmd)
        # Inject spec path automatically for generation/verification
        if phase.name == "Generation":
            out_dir = GEN_DIR / "output"
            out_dir.mkdir(parents=True, exist_ok=True)
            if self._latest_spec is None:
                self._latest_spec = _latest_json(GEN_DIR / "specs")
            if self._latest_spec:
                cmd += ["-s", str(self._latest_spec), "-o", str(out_dir)]
        if phase.name == "Verification":
            if self._latest_spec is None:
                self._latest_spec = _latest_json(VER_DIR / "specs")
            if self._latest_spec:
                ver_spec = VER_DIR / "specs" / self._latest_spec.name
                cmd += ["-Spec", str(ver_spec)]
        self.log_line(f"[phase] {phase.name} starting")
        self._current_thread = RunnerThread(cmd, phase.cwd)
        self._current_thread.log.connect(self.log_line)
        self._current_thread.finished_ok.connect(lambda ok: self.on_phase_done(ok, phase_idx))
        self._current_thread.start()

    def run_all(self) -> None:
        if self.chk_clear.isChecked():
            _clear_specs_and_dut(self.log_line)
        self._pipeline = [0, 1, 2]
        if self.chk_skip_gen.isChecked():
            self._pipeline = [0, 2]
        self._phase_index = 0
        self.set_progress(0, len(self._pipeline))
        self.run_phase(self._pipeline[self._phase_index])

    def on_phase_done(self, ok: bool, phase_idx: int) -> None:
        self.log_line(f"[phase] {PHASES[phase_idx].name} {'OK' if ok else 'FAILED'}")
        if ok and PHASES[phase_idx].name == "Front End Chat":
            spec = _latest_json(FE_DIR)
            if spec:
                targets = _copy_spec_to_targets(spec)
                self._latest_spec = targets[0]
                self.log_line("[spec] copied to Generationv2/specs and Verification/specs")
        if ok and PHASES[phase_idx].name == "Generation":
            _sync_gen_output_to_dut(self.log_line)
        if not self._pipeline:
            return
        self._phase_index += 1
        self.set_progress(self._phase_index, len(self._pipeline))
        if ok and self._phase_index < len(self._pipeline):
            self.run_phase(self._pipeline[self._phase_index])

    def upload_rtl(self) -> None:
        files, _ = QFileDialog.getOpenFileNames(
            self,
            "Select RTL files",
            str(ROOT),
            "Verilog Files (*.v *.sv);;All Files (*)"
        )
        if not files:
            return
        self.log_line(f"[rtl] selected {len(files)} files")
        # Placeholder: future copy/index step.


def main() -> int:
    app = QApplication([])
    w = OrchestratorGUI()
    w.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
