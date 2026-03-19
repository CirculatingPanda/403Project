# ECEN403 Workspace

Cross-platform notes:

- `orchestrator.py` now prefers the active Python interpreter and selects the verification wrapper by OS.
- Windows verification uses [run.ps1](/c:/Users/Justin%20Krupa/ECEN403/Verification/run.ps1).
- Linux verification uses [run.sh](/c:/Users/Justin%20Krupa/ECEN403/Verification/run.sh), which is suitable for MobaXterm SSH sessions.

Typical Linux flow:

```bash
python3 orchestrator.py generate --spec Generationv2/specs/<spec>.json
python3 orchestrator.py verify --spec Verification/specs/<spec>.json
python3 orchestrator.py synthesize --design <design_name> --design-type seq --stream
```

Synthesis handoff:

- The orchestrator stages verified RTL into [orchestrator_sync](/c:/Users/Justin%20Krupa/ECEN403/Capstone-LLM-Chip-Design-1/synthesis_pnr/capstone/rtl/orchestrator_sync).
- The synthesis subsystem runs [automation_final.py](/c:/Users/Justin%20Krupa/ECEN403/Capstone-LLM-Chip-Design-1/synthesis_pnr/capstone/scripts/automation_final.py) with `--rtl-dir` pointed at that staging folder.
- `automation_final.py` auto-detects the top module if `--top` is omitted, prefers `constraints.sdc` or a single local `*.sdc` in the staged RTL folder, and otherwise falls back to the sample sequential/combinational SDC.
- Cadence outputs are written by the automation into `capstone/scripts/outputs`, `capstone/scripts/out`, and generated TCL files in `capstone/scripts` plus `capstone/PnR`.
