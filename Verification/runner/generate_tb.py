#!/usr/bin/env python3
import os, sys, json, argparse, re, textwrap, subprocess, difflib, time
from pathlib import Path
from typing import Tuple, List, Dict, Any, Optional

# Make parent (Verification/) importable so we can import verification.py
RUNNER_DIR = Path(__file__).resolve().parent
ROOT_DIR   = RUNNER_DIR.parent
sys.path.append(str(ROOT_DIR))

def rel_to_root(p: Path) -> str:
    """
    Return a path relative to ROOT_DIR, to avoid spaces in absolute paths.
    If that fails for any reason, fall back to the string form.
    """
    try:
        return os.path.relpath(p, ROOT_DIR)
    except Exception:
        return str(p)


# NOTE: GuardedEditEngine import for slice application
from verification import apply_edits_with_provider, TamusAdapter, GuardedEditEngine, EchoAdapter  # type: ignore

TPL_DIR = ROOT_DIR / "templates"   # your layout

def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")

def write(p: Path, s: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(s, encoding="utf-8")

def available_template_dirs() -> list[Path]:
    out = []
    if not TPL_DIR.exists():
        return out
    for sub in TPL_DIR.iterdir():
        if sub.is_dir() and (sub / "tb_template.sv").exists():
            out.append(sub)
    return sorted(out)

def resolve_template_for_kind(kind: str) -> Path | None:
    """
    Heuristics mapping spec['kind'] -> templates/<dir>/tb_template.sv
    """
    direct = {
        "sram_controller": "sram_sync",
        "dualport_sram_controller": "sram_async",
        "fifo_controller": "fifo",
        "rom_controller": "rom",
        "sdram_controller": "sdram",
        "ddr_controller": "ddr",
        "ddr2_controller": "ddr2",
        "ddr_lite_controller": "ddr_lite",
    }
    if kind in direct:
        cand = TPL_DIR / direct[kind] / "tb_template.sv"
        if cand.exists():
            return cand

    kind_l = kind.lower()
    prefs = ["sram_sync", "sram_async", "ddr2", "ddr_lite", "ddr", "sdram", "fifo", "rom"]
    for name in prefs:
        if name in kind_l or any(tok in kind_l for tok in name.split("_")):
            cand = TPL_DIR / name / "tb_template.sv"
            if cand.exists():
                return cand
    return None

def _bool_to_bit(v) -> str:
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, str):
        return "1" if v.strip().lower() in ("1","true","yes","y","little","le") else "0"
    try:
        return "1" if int(v) != 0 else "0"
    except Exception:
        return "0"

def render_placeholders(template_text: str, spec: dict) -> str:
    """
    Very small mustache-style substitution for {{TOKEN}} found in the template.
    Only replaces the specific keys we support. Leaves anything unknown alone.
    """
    data_width = int(spec.get("data_width", 32))
    addr_width = int(spec.get("addr_width", 16))
    endian     = spec.get("endian", "little")
    clk_mhz    = float((spec.get("sim", {}) or {}).get("clock_mhz", 100))
    num_txns   = int((spec.get("sim", {}) or {}).get("num_transactions", 200))

    golden_stub = "/* golden SRAM sync model omitted for this config */"
    preload     = "/* no preload */"

    out = template_text
    out = out.replace("{{DATA_WIDTH}}", str(data_width))
    out = out.replace("{{ADDR_WIDTH}}", str(addr_width))
    out = out.replace("{{ENDIAN_IS_LITTLE}}", _bool_to_bit(endian in ("little","Little","LITTLE",True,"true","1")))
    out = out.replace("{{CLK_MHZ}}", f"{clk_mhz:g}")
    out = out.replace("{{NUM_TRANSACTIONS}}", str(num_txns))
    out = out.replace("{{INCLUDE_GOLDEN_SRAM_SYNC}}", golden_stub)
    out = out.replace("{{PRELOAD_SNIPPET}}", preload)
    return out

# ----------------------------
# Checker (AI-first, static fallback)
# ----------------------------

CHECKER_SYSTEM_PROMPT = """\
You are an expert SystemVerilog testbench reviewer (“checker”).
Task: Decide APPROVE or REJECT for the testbench below and, if REJECT, propose minimal, safe FIXES.

Constraints:
- Target simulator: Icarus Verilog (iverilog) with -g2012; avoid unsupported SV constructs.
- The generator runs in STAGED mode (slice-by-slice). Prefer to fix issues localized to the most recently edited regions; only touch unrelated regions if necessary to reach APPROVE.
- Enforce Icarus quirks:
  * Declarations inside procedural blocks must appear before any executable statements.
  * Avoid 'final' blocks; prefer an 'initial' block with a wait-condition for completion.
  * Use $display/$fatal rather than $error.
- NO code fences. Respond with strict JSON ONLY.
- JSON schema:
  {
    "verdict": "APPROVE" | "REJECT",
    "reasons": [ "short bullet", ... ],
    "edits": [
      { "kind": "replace_once", "find": "exact string", "replace": "replacement" } |
      { "kind": "insert_after", "anchor": "exact string to locate", "insert": "string to insert" } |
      { "kind": "insert_before", "anchor": "exact string to locate", "insert": "string to insert" }
    ]
  }

Guidance:
- Common iverilog pitfalls: stray '{{...}}' placeholders, '@LLM_EDIT' remnants, code fences, merge markers ('<<<<', '>>>>'), undefined identifiers, missing 'endmodule', etc.
- Keep edits minimal and safe.
"""

SYNTAX_FIX_SYSTEM = """\
You are an expert SystemVerilog compile-fix assistant for Icarus Verilog (-g2012).
Goal: propose minimal edits to the testbench ONLY to fix the syntax errors below.

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

def _safe_json_load(s: str) -> Optional[Dict[str, Any]]:
    try:
        return json.loads(s)
    except Exception:
        return None

def _strip_any_fences(s: str) -> str:
    return re.sub(r"^```(?:json)?\s*|\s*```$", "", s.strip(), flags=re.DOTALL)

def ai_check(tb_text: str,
             spec: dict,
             provider: TamusAdapter,
             allowed_regions: Optional[List[str]] = None) -> Tuple[str, List[str], List[Dict[str, str]]]:
    scope_hint = ""
    if allowed_regions:
        scope_hint = (
            "Scope restriction: ONLY review and propose edits within these @LLM_EDIT regions: "
            f"{', '.join(allowed_regions)}. Ignore issues outside these regions.\n\n"
        )
    user_prompt = f"""{scope_hint}Review the following SystemVerilog testbench for compilation readiness:

---BEGIN_TB---
{tb_text}
---END_TB---

Remember: return STRICT JSON only per the schema."""
    raw = None
    if hasattr(provider, "complete"):
        raw = provider.complete(CHECKER_SYSTEM_PROMPT, user_prompt)  # type: ignore
    elif hasattr(provider, "chat"):
        raw = provider.chat([
            {"role":"system","content":CHECKER_SYSTEM_PROMPT},
            {"role":"user","content":user_prompt},
        ])  # type: ignore
    else:
        wrapper = textwrap.dedent(f"""
        /* @LLM_EDIT
        {CHECKER_SYSTEM_PROMPT}

        USER:
        {user_prompt}
        @END */
        """)
        raw = apply_edits_with_provider(template_text=wrapper, spec=spec, provider=provider)

    if not isinstance(raw, str):
        raise RuntimeError("Checker provider returned non-string output")

    js = _safe_json_load(_strip_any_fences(raw))
    if not js or "verdict" not in js:
        raise RuntimeError("Checker JSON parse failed")

    verdict = str(js.get("verdict", "")).upper()
    reasons = list(js.get("reasons", [])) if isinstance(js.get("reasons", []), list) else []
    edits   = list(js.get("edits", [])) if isinstance(js.get("edits", []), list) else []
    return verdict, reasons, edits

STATIC_RULES = [
    ("Leftover mustache placeholders", re.compile(r"\{\{[^}]+\}\}")),
    # NOTE: we intentionally do NOT treat '@LLM_EDIT' markers as an error anymore.
    ("Merge conflict markers", re.compile(r"<<<<|>>>>|====")),
    ("Markdown code fences", re.compile(r"```")),
]

def static_check(tb_text: str,
                 allowed_regions: Optional[List[str]] = None) -> Tuple[str, List[str], List[Dict[str,str]]]:
    reasons = []
    if allowed_regions:
        engine = GuardedEditEngine(provider=EchoAdapter(model="echo"))
        regions = engine._find_regions(tb_text)  # type: ignore[attr-defined]
        want = {str(n).strip() for n in allowed_regions}
        region_text = "\n".join([r.original_text for r in regions if r.name in want])
        for name, rx in STATIC_RULES:
            if rx.search(region_text):
                reasons.append(name)
    else:
        for name, rx in STATIC_RULES:
            if rx.search(tb_text):
                reasons.append(name)

        mod_count = len(re.findall(r"\bmodule\b", tb_text))
        endmod_count = len(re.findall(r"\bendmodule\b", tb_text))
        if mod_count != endmod_count:
            reasons.append(f"module/endmodule count mismatch ({mod_count} vs {endmod_count})")

    if reasons:
        return "REJECT", reasons, []
    return "APPROVE", [], []

def apply_edits(tb: str, edits: List[Dict[str,str]]) -> Tuple[str, int]:
    out = tb
    applied = 0
    for e in edits:
        kind = e.get("kind", "")
        if kind == "replace_once":
            find = e.get("find","")
            repl = e.get("replace","")
            if find and find in out:
                out = out.replace(find, repl, 1)
                applied += 1
        elif kind == "insert_after":
            anchor = e.get("anchor","")
            insert = e.get("insert","")
            if anchor and anchor in out:
                out = out.replace(anchor, anchor + insert, 1)
                applied += 1
        elif kind == "insert_before":
            anchor = e.get("anchor","")
            insert = e.get("insert","")
            if anchor and anchor in out:
                out = out.replace(anchor, insert + anchor, 1)
                applied += 1
        # unknown kinds ignored for safety
    return out, applied

def _find_allowed_spans(tb_text: str, allowed_regions: Optional[List[str]]) -> List[Tuple[int, int]]:
    if not allowed_regions:
        return []
    engine = GuardedEditEngine(provider=EchoAdapter(model="echo"))
    regions = engine._find_regions(tb_text)  # type: ignore[attr-defined]
    want = {str(n).strip() for n in allowed_regions}
    spans = [(r.start_idx, r.end_idx) for r in regions if r.name in want]
    return spans

def _range_in_spans(start: int, end: int, spans: List[Tuple[int, int]]) -> bool:
    if start == end:
        return any(s <= start <= e for s, e in spans)
    return any(start >= s and end <= e for s, e in spans)

def _changes_outside_allowed(tb_before: str,
                             tb_after: str,
                             allowed_regions: Optional[List[str]]) -> bool:
    if not allowed_regions:
        return False
    spans = _find_allowed_spans(tb_before, allowed_regions)
    if not spans:
        return True
    matcher = difflib.SequenceMatcher(a=tb_before, b=tb_after)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        if not _range_in_spans(i1, i2, spans):
            return True
    return False

def _strip_sv_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//.*", "", text)
    return text

def _region_has_non_comment_content(tb_text: str, region_name: str) -> bool:
    engine = GuardedEditEngine(provider=EchoAdapter(model="echo"))
    regions = engine._find_regions(tb_text)  # type: ignore[attr-defined]
    for r in regions:
        if r.name == region_name:
            cleaned = _strip_sv_comments(r.original_text)
            return bool(cleaned.strip())
    return True

def run_tb_engineer(template_text: str, spec: dict, engineer_model: str) -> str:
    return apply_edits_with_provider(
        template_text=template_text,
        spec=spec,
        provider=TamusAdapter(model=engineer_model),
    )

def _syntax_fix(tb_text: str, compile_out: str, provider: TamusAdapter) -> List[Dict[str, str]]:
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
    raw = provider.complete(SYNTAX_FIX_SYSTEM, user)  # type: ignore
    if not isinstance(raw, str):
        return []
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

def run_checker_loop(initial_tb: str,
                     spec: dict,
                     checker_model: str,
                     max_iters: int,
                     allowed_regions: Optional[List[str]] = None) -> Tuple[str, Dict[str, Any]]:
    """
    AI checker + static checker loop.
    static_check is *always* applied; it can veto an APPROVE from the AI checker.
    """
    provider = TamusAdapter(model=checker_model)
    tb = _comment_stray_end_of_test_line(initial_tb)
    history: List[Dict[str, Any]] = []

    retry_max = int(os.getenv("TB_CHECKER_RETRIES", "3"))
    retry_sleep = float(os.getenv("TB_CHECKER_RETRY_SLEEP", "2.0"))

    seen_hashes: set[int] = set()
    seen_counts: Dict[int, int] = {}
    last_reason_sig: Optional[Tuple[str, ...]] = None
    repeat_reason_count = 0
    repeat_tb_max = int(os.getenv("TB_CHECKER_REPEAT_TB_MAX", "2"))
    soft_stop_max = int(os.getenv("TB_CHECKER_SOFT_STOP_MAX", "2"))
    soft_stop_count = 0

    for i in range(1, max_iters+1):
        print(f"[checker] iter {i}/{max_iters}: starting review", flush=True)
        tb_hash = hash(tb)
        seen_counts[tb_hash] = seen_counts.get(tb_hash, 0) + 1
        if tb_hash in seen_hashes and seen_counts[tb_hash] > (repeat_tb_max + 1):
            history.append({
                "iter": i,
                "verdict": "REJECT",
                "reasons": ["No progress: testbench content repeated across iterations."],
                "edits_applied": 0,
            })
            return tb, {
                "iterations": i,
                "history": history,
                "approved": False,
                "note": "Repeated TB content; stopping to avoid oscillation.",
            }
        seen_hashes.add(tb_hash)

        checker_error = True
        for attempt in range(1, retry_max + 1):
            try:
                print("[checker] contacting LLM checker...", flush=True)
                verdict, reasons, edits = ai_check(tb, spec, provider, allowed_regions=allowed_regions)
                checker_error = False
                break
            except Exception as exc:
                print(f"[checker] ERROR: LLM checker exception: {exc}", flush=True)
                if attempt < retry_max:
                    print(f"[checker] retrying LLM checker ({attempt}/{retry_max}) after {retry_sleep}s", flush=True)
                    time.sleep(retry_sleep)
        if checker_error:
            verdict, reasons, edits = "REJECT", ["AI checker error; falling back to static"], []

        # Always run static_check and let it veto approvals
        static_verdict, static_reasons, _ = static_check(tb, allowed_regions=allowed_regions)
        if static_verdict == "REJECT":
            if verdict == "APPROVE":
                verdict = "REJECT"
            reasons = reasons + [f"static_check: {r}" for r in static_reasons]
        elif checker_error:
            if verdict != "APPROVE":
                verdict = "APPROVE"
            reasons = reasons + ["LLM checker unavailable; static-only approval"]
        if allowed_regions:
            for region_name in allowed_regions:
                if not _region_has_non_comment_content(tb, region_name):
                    if verdict == "APPROVE":
                        verdict = "REJECT"
                    reasons.append(
                        f"Region '{region_name}' contains only comments/placeholders; must emit real code."
                    )

        history.append({
            "iter": i,
            "verdict": verdict,
            "reasons": reasons,
            "edits_applied": len(edits),
        })

        reason_sig = tuple(reasons)
        if verdict != "APPROVE":
            if reason_sig == last_reason_sig:
                repeat_reason_count += 1
            else:
                repeat_reason_count = 1
            last_reason_sig = reason_sig
            if repeat_reason_count >= 3:
                return tb, {
                    "iterations": i,
                    "history": history,
                    "approved": False,
                    "note": "Repeated checker reasons; stopping early.",
                }

        if verdict == "APPROVE":
            print("[checker] verdict=APPROVE", flush=True)
            return tb, {"iterations": i, "history": history, "approved": True}

        if edits:
            tb_before = tb
            tb_after, applied = apply_edits(tb, edits)
            if _changes_outside_allowed(tb_before, tb_after, allowed_regions):
                history.append({
                    "iter": i,
                    "verdict": "REJECT",
                    "reasons": ["LLM edits touched regions outside the allowed slice."],
                    "edits_applied": applied,
                })
                if soft_stop_count < soft_stop_max:
                    soft_stop_count += 1
                    last_reason_sig = None
                    continue
                return tb_before, {
                    "iterations": i,
                    "history": history,
                    "approved": False,
                    "note": "Edits outside allowed regions; stopping.",
                }
            tb = icarus_fixups(tb_after)
            if applied == 0 or tb == tb_before:
                history.append({
                    "iter": i,
                    "verdict": "REJECT",
                    "reasons": ["LLM edits did not apply or made no changes."],
                    "edits_applied": applied,
                })
                if soft_stop_count < soft_stop_max:
                    soft_stop_count += 1
                    last_reason_sig = None
                    continue
                return tb, {
                    "iterations": i,
                    "history": history,
                    "approved": False,
                    "note": "Edits failed to modify TB; stopping.",
                }
            print(f"[checker] verdict=REJECT, applied {applied} edits", flush=True)
        else:
            if soft_stop_count < soft_stop_max:
                soft_stop_count += 1
                last_reason_sig = None
                continue
            return tb, {"iterations": i, "history": history, "approved": False, "note": "Rejected without edits."}

    return tb, {"iterations": max_iters, "history": history, "approved": False, "note": "Max iterations reached."}

# ---------- Icarus auto-fixups (no manual intervention) ----------

INITIAL_BLOCK_RE = re.compile(r"(initial\s+begin)(?P<body>.*?)(end)", re.S)

def _fix_num_txns_to_localparam(text: str) -> str:
    return re.sub(r"(?m)^\s*int\s+NUM_TXNS\s*=\s*([0-9_']+)\s*;",
                  r"localparam int NUM_TXNS = \1;", text)

FINAL_BLOCK_RE = re.compile(r"(?ms)^\s*final\s+begin\s*(.*?)\s*end\s*$")

def _replace_final_with_initial_wait(text: str) -> str:
    if not FINAL_BLOCK_RE.search(text):
        return text

    replacement = '''initial begin
  wait (txn_count >= NUM_TXNS);
  if (err_count == 0) begin
    $display("RESULT: PASS");
    $finish;
  end else begin
    $display("RESULT: FAIL");
    $fatal(1);
  end
end'''

    return re.sub(FINAL_BLOCK_RE, replacement, text)


def _hoist_decls_in_initial_blocks(text: str) -> str:
    def _process_block(m: re.Match) -> str:
        head, body, tail = m.group(1), m.group("body"), m.group(3)
        lines = body.splitlines(True)

        # declaration detection (simple, conservative)
        decl_rx = re.compile(
            r"^\s*(?:logic|bit|byte|shortint|int|longint|integer)"
            r"(?:\s+\[[^;\n]*\])?\s+[\w\[\]\s,:\.]*;\s*$",
            re.M,
        )
        comment_blank_rx = re.compile(r"^\s*(?://.*|/\*.*\*/)?\s*$")

        # collect leading decl/comment/blank lines
        decls, consumed = [], 0
        for ln in lines:
            if comment_blank_rx.match(ln) or decl_rx.match(ln):
                decls.append(ln)
                consumed += 1
            else:
                break

        remainder = "".join(lines[consumed:])

        # fish out any later declarations and hoist them
        later_decls: list[str] = []
        def repl_decl(mm: re.Match) -> str:
            s = mm.group(0)
            later_decls.append(s)
            return ""  # remove from later position

        remainder = decl_rx.sub(repl_decl, remainder)

        # assemble new block
        decl_block = "".join(decls) + "".join(later_decls)
        if decl_block and not decl_block.endswith("\n"):
            decl_block += "\n"

        return f"{head}{decl_block}{remainder}{tail}"

    return re.sub(INITIAL_BLOCK_RE, _process_block, text)

# split initialized decls inside initial blocks (silence Icarus warnings)
DECL_INIT_IN_INITIAL_RE = re.compile(r"(?ms)(initial\s+begin)(?P<body>.*?)(end)")
SIMPLE_INIT_LINE_RE = re.compile(
    r"^\s*(?P<type>(?:logic|bit|byte|shortint|int|longint|integer)(?:\s+\[[^\]]+\])?)\s+"
    r"(?P<name>[A-Za-z_]\w*)\s*=\s*(?P<rhs>[^;]+);\s*$"
)

def _split_initialized_decls_in_initials(text: str) -> str:
    def _transform_block(m: re.Match) -> str:
        head, body, tail = m.group(1), m.group("body"), m.group(3)
        out_lines: List[str] = []
        for ln in body.splitlines(True):
            mi = SIMPLE_INIT_LINE_RE.match(ln)
            if mi:
                vartype = mi.group("type")
                name    = mi.group("name")
                rhs     = mi.group("rhs")
                out_lines.append(f"{vartype} {name};\n")
                out_lines.append(f"{name} = {rhs};\n")
            else:
                out_lines.append(ln)
        return f"{head}{''.join(out_lines)}{tail}"
    return re.sub(DECL_INIT_IN_INITIAL_RE, _transform_block, text)

# rewrite unpacked function port (Icarus limitation)
PACK_BYTES_UNPACKED_RE = re.compile(
    r"(?ms)function\s+automatic\s+\[DATA_W-1:0\]\s+pack_bytes\s*\(\s*input\s+logic\s*\[\s*7:0\s*\]\s*B\s*\[\s*BE_W\s*\]\s*\)\s*;.*?endfunction"
)

def _rewrite_pack_bytes_unpacked_port(text: str) -> str:
    replacement = r"""
function automatic [DATA_W-1:0] pack_bytes(input logic [8*BE_W-1:0] B_flat);
  int i;
  pack_bytes = '0;
  for (i = 0; i < BE_W; i++) begin
    if (LITTLE_ENDIAN) begin
      pack_bytes[i*8 +: 8] = B_flat[i*8 +: 8];
    end else begin
      pack_bytes[(BE_W-1-i)*8 +: 8] = B_flat[i*8 +: 8];
    end
  end
endfunction
""".strip()
    return re.sub(PACK_BYTES_UNPACKED_RE, replacement, text)


NBYTES_LOCALPARAM_RE = re.compile(r"\blocalparam\s+int\s+NBYTES\b")

def _hoist_nbytes_localparam(text: str) -> str:
    """
    Icarus requires the replication count in {NBYTES{...}} to be a constant.
    If the LLM introduced 'int NBYTES;' as a procedural variable, this rewrites
    things so NBYTES becomes a top-level localparam and removes the local 'int NBYTES;'.
    """
    # If NBYTES never appears, nothing to do
    if "NBYTES" not in text:
        return text

    # If we already have a localparam int NBYTES, assume it's fine
    if NBYTES_LOCALPARAM_RE.search(text):
        # Still clean up any accidental 'int NBYTES;' locals
        text = re.sub(r"^\s*int\s+NBYTES\s*(=.*)?;\s*$", "", text, flags=re.MULTILINE)
        return text

    # 1) Remove any 'int NBYTES;' or 'int NBYTES = ...;' local declarations
    text = re.sub(r"^\s*int\s+NBYTES\s*(=.*)?;\s*$", "", text, flags=re.MULTILINE)

    # 2) Insert a top-level localparam int NBYTES = DATA_W/8;
    #    Ideally right after BE_W is defined.
    m = re.search(r"(localparam\s+int\s+BE_W\s*=.*?;\s*)", text)
    insert_line = "  localparam int NBYTES = (DATA_W/8);\n"
    if m:
        # Insert after BE_W line
        before = text[:m.end()]
        after  = text[m.end():]
        text = before + "\n" + insert_line + after
    else:
        # Fallback: try after ADDR_W
        m2 = re.search(r"(localparam\s+int\s+ADDR_W\s*=.*?;\s*)", text)
        if m2:
            before = text[:m2.end()]
            after  = text[m2.end():]
            text = before + "\n" + insert_line + after
        else:
            # Last resort: shove it near the top of the module
            m3 = re.search(r"module\s+tb\s*;.*?\n", text, flags=re.DOTALL)
            if m3:
                before = text[:m3.end()]
                after  = text[m3.end():]
                text = before + "\n" + insert_line + after
            else:
                # Couldn't find a good place; just append at the top
                text = insert_line + text

    return text

def _repair_illegal_lvalues(text: str) -> str:
    """
    Fix common illegal lvalue patterns introduced by LLMs (e.g. assigning to expressions).
    Heuristic: replace "((X) & MASK) = Y;" with "X = (Y) & MASK;".
    """
    pat = re.compile(
        r"(?P<lhs>\(\(\s*(?P<var>\w+)\s*\)\s*&\s*(?P<mask>\{[^;]*?\}|[^\)]+?)\s*\))\s*=\s*(?P<rhs>[^;]+);"
    )
    def repl(m: re.Match) -> str:
        var = m.group("var")
        mask = m.group("mask")
        rhs = m.group("rhs")
        return f"{var} = ({rhs}) & {mask};"
    return pat.sub(repl, text)

# NEW: strip / rewrite break statements (Icarus “sorry: break statements not supported”)
BREAK_RE = re.compile(r"\bbreak\s*;")

def _remove_break_statements(text: str) -> str:
    """
    Icarus (current version in this flow) does not support 'break' in loops.
    For testbenches we can safely elide 'break;' and keep statements syntactically valid.
    - bare 'break;' becomes ';'
    - 'if (cond) break;' becomes 'if (cond) ;'
    """
    return BREAK_RE.sub(";", text)

ADDR_SLICE_RE = re.compile(r"(?P<expr>\([^\)]+\)|'h[0-9a-fA-F_]+|[A-Za-z_]\w*)\s*\[ADDR_W-1:0\]")

def _rewrite_addr_slices(text: str) -> str:
    """
    Icarus rejects slicing on literals/expressions like ('h40 + i)[ADDR_W-1:0].
    Rewrite to a mask: (expr & {ADDR_W{1'b1}}).
    """
    def _repl(m: re.Match) -> str:
        expr = m.group("expr")
        return f"(({expr}) & {{ADDR_W{{1'b1}}}})"
    return ADDR_SLICE_RE.sub(_repl, text)

BAD_ADDR_TYPE_RE = re.compile(r"\(\(logic\)\s*&\s*\{ADDR_W\{1'b1\}\}\)")

def _fix_bad_addr_type(text: str) -> str:
    """
    Some LLM outputs accidentally use an expression where a type is required:
      ((logic) & {ADDR_W{1'b1}}) a;
    Rewrite to a valid packed type for addresses.
    """
    return BAD_ADDR_TYPE_RE.sub("logic [ADDR_W-1:0]", text)

BAD_INPUT_TYPE_RE = re.compile(r"\(\(input\)\s*&\s*\{ADDR_W\{1'b1\}\}\)")

def _fix_bad_input_type(text: str) -> str:
    """
    Fix malformed input type emitted by LLM inside task port lists:
      ((input) & {ADDR_W{1'b1}}) a
    """
    return BAD_INPUT_TYPE_RE.sub("input logic [ADDR_W-1:0]", text)


def _hoist_model_mem_to_module_scope(text: str) -> str:
    """
    If a model_mem array is declared inside an initial block, move it to module scope.
    Heuristic: detect 'initial begin' that declares 'logic ... model_mem [...]' and hoist.
    """
    init_re = re.compile(r"(initial\s+begin)(?P<body>.*?)(end)", re.S)
    m = init_re.search(text)
    if not m:
        return text
    body = m.group("body")
    decl_re = re.compile(r"(?m)^\s*(logic|reg)\s+\[.*?\]\s+model_mem\s*\[.*?\]\s*;\s*$")
    decls = decl_re.findall(body)
    if not decls:
        return text
    # Extract full decl lines
    decl_lines = decl_re.findall(body)
    # Actually capture full lines using finditer
    decl_texts = [mm.group(0) for mm in decl_re.finditer(body)]
    if not decl_texts:
        return text
    # Remove from initial block body
    new_body = body
    for dt in decl_texts:
        new_body = new_body.replace(dt, "")
    # Insert before first initial block
    hoist_block = "\n  // hoisted model_mem from initial block\n  " + "\n  ".join(d.strip() for d in decl_texts) + "\n"
    new_text = text[:m.start()] + hoist_block + text[m.start():]
    new_text = new_text.replace(body, new_body, 1)
    return new_text


END_OF_TEST_RE = re.compile(r"(?m)^(?P<ws>\s*)(?P<line>end-of-test.*)$")

def _comment_stray_end_of_test_line(text: str) -> str:
    """
    Some LLM outputs insert a plain text line like:
      end-of-test to avoid infinite run in skeleton
    This is a syntax error in SV; comment it out.
    """
    def _repl(m: re.Match) -> str:
        return f"{m.group('ws')}// {m.group('line')}"
    return END_OF_TEST_RE.sub(_repl, text)

def _fix_module_endmodule_mismatch(text: str) -> str:
    """
    If there's a single extra 'endmodule' (or missing), try a minimal fix.
    This is a heuristic to unblock static_check when LLM injects stray endmodule.
    """
    mod_count = len(re.findall(r"\bmodule\b", text))
    endmod_count = len(re.findall(r"\bendmodule\b", text))
    if mod_count == endmod_count:
        return text
    if endmod_count == mod_count + 1:
        # Drop the last 'endmodule'
        return re.sub(r"(endmodule\b)(?!.*endmodule\b)", "", text, flags=re.S)
    if mod_count == endmod_count + 1:
        # Append a missing endmodule at EOF
        return text.rstrip() + "\nendmodule\n"
    return text


def icarus_fixups(tb_text: str) -> str:
    tb_text = _fix_num_txns_to_localparam(tb_text)
    tb_text = _replace_final_with_initial_wait(tb_text)
    tb_text = _hoist_decls_in_initial_blocks(tb_text)
    tb_text = _split_initialized_decls_in_initials(tb_text)
    tb_text = _rewrite_pack_bytes_unpacked_port(tb_text)
    tb_text = _hoist_nbytes_localparam(tb_text)
    tb_text = _remove_break_statements(tb_text)
    tb_text = _rewrite_addr_slices(tb_text)
    tb_text = _fix_bad_addr_type(tb_text)
    tb_text = _fix_bad_input_type(tb_text)
    tb_text = _hoist_model_mem_to_module_scope(tb_text)
    tb_text = _repair_illegal_lvalues(tb_text)
    tb_text = tb_text.replace("$error", "$display")
    tb_text = _comment_stray_end_of_test_line(tb_text)
    tb_text = _fix_module_endmodule_mismatch(tb_text)
    return tb_text

# ---------- Icarus syntax pre-check ----------

DEFAULT_DUT_MODULE = "sram_sync_ctrl"

def icarus_syntax_check(tb_path: Path) -> Tuple[bool, str]:
    """
    Run a lightweight Icarus syntax check on the generated TB alone.
    To avoid 'unknown module' errors for the DUT, we comment out the DUT
    instantiation in a temporary copy and check that file instead.
    """
    original = tb_path.read_text(encoding="utf-8")

    # Regex to find the DUT instantiation (with or without parameters)
    inst_re = re.compile(
        rf"({DEFAULT_DUT_MODULE}\s*#\s*\([^;]*?\)\s+\w+\s*\([^;]*?\)\s*;|"
        rf"{DEFAULT_DUT_MODULE}\s+\w+\s*\([^;]*?\)\s*;)",
        re.S,
    )

    def _comment_dut(m: re.Match) -> str:
        body = m.group(0)
        # Avoid closing our comment if someone ever writes '*/' in the instantiation
        safe_body = body.replace("*/", "* /")
        return "/* DUT instantiation elided for syntax check */\n/* " + safe_body + " */"

    tb_syntax = inst_re.sub(_comment_dut, original)

    tmp_path = tb_path.with_name(tb_path.stem + "_syntax.sv")
    tmp_path.write_text(tb_syntax, encoding="utf-8")

    cmd = ["iverilog", "-g2012", "-tnull", str(tmp_path)]
    print(f"[generate_tb] Icarus syntax pre-check: {' '.join(cmd)}")
    proc = subprocess.run(cmd, capture_output=True, text=True)

    output = ""
    if proc.stdout:
        output += proc.stdout
    if proc.stderr:
        output += proc.stderr

    if proc.returncode != 0:
        print("[generate_tb] Icarus syntax check FAILED.")
        if proc.stdout:
            print("----- iverilog stdout -----")
            print(proc.stdout)
        if proc.stderr:
            print("----- iverilog stderr -----")
            print(proc.stderr)
        return False, output
    else:
        print("[generate_tb] Icarus syntax check PASSED.")
        return True, output

# ---------- staged generation helpers ----------

# Define the slice plan by @LLM_EDIT region names present in templates
SLICE_PLAN: list[list[str]] = [
    ["TIMING_CYCLES"],                  # initializations
    ["TASK_DO_WRITE", "TASK_DO_READ"],  # driver tasks
    ["MAIN_SCENARIO"],                  # main traffic
    ["EMIT_RESULTS"],                   # result emitter
]

def apply_slice(template_text: str,
                spec: dict,
                provider: TamusAdapter,
                include_regions: list[str],
                extra_tasks: Optional[List[str]] = None) -> str:
    """Apply LLM edits only to the specified @LLM_EDIT region names."""
    engine = GuardedEditEngine(provider=provider)
    return engine.apply_llm_edits(
        template_text,
        spec,
        include_regions=include_regions,
        extra_tasks=extra_tasks,
    )

def _derive_retry_tasks(reasons: List[str], region_group: List[str]) -> List[str]:
    tasks: List[str] = []
    if any("outside the allowed slice" in r for r in reasons):
        tasks.append(
            "STRICT: Only edit the allowed @LLM_EDIT regions for this slice. "
            "Do not modify any other region or non-LLM text."
        )
    if any("associative array" in r or ".exists()" in r for r in reasons):
        tasks.append(
            "Avoid associative arrays and .exists(); Icarus Verilog does not support them. "
            "Use fixed-size arrays and/or simple bitmaps instead."
        )
    if any("$error" in r for r in reasons):
        tasks.append("Do not use $error; use $display/$fatal only.")
    if any("final" in r for r in reasons):
        tasks.append("Do not use 'final' blocks; use 'initial' with wait/timeout.")
    if any("Region" in r and "only comments" in r for r in reasons):
        tasks.append("Emit real code (not just comments/placeholders) in the allowed region.")
    if tasks:
        tasks.insert(0, f"Slice context: only edit regions {region_group}.")
    return tasks

# ---------- auto-stub DUT (no manual drop-ins) ----------

def collect_dut_files(dut_dir: Path) -> list[Path]:
    """
    Collect all DUT .sv/.v files under dut_dir (non-recursive or recursive as needed).
    These will be added to the Icarus filelist *instead* of the auto-stub when present.
    """
    if not dut_dir.exists():
        return []
    files: list[Path] = []
    for p in dut_dir.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix.lower() not in (".sv", ".v"):
            continue
        if p.is_file():
            files.append(p.resolve())
    return sorted(files)

# ---------- DUT/TB port consistency checks ----------

def _extract_tb_dut_ports(tb_text: str, dut_module: str = DEFAULT_DUT_MODULE) -> List[str]:
    """
    Find the named-port instantiation of the DUT module inside the testbench
    and return the list of *formal* port names in that instantiation.
    """
    inst_re = re.compile(
        rf"{dut_module}\s*"
        r"(?:#\s*\([^;]*?\)\s*)?"  # optional parameter block
        r"\w+\s*\((?P<ports>[^;]*?)\)\s*;",
        re.S,
    )
    m = inst_re.search(tb_text)
    if not m:
        raise RuntimeError(
            f"Could not find an instantiation of '{dut_module}' in the generated testbench."
        )

    port_block = m.group("ports")
    formals = re.findall(r"\.(\w+)\s*\(", port_block)
    if not formals:
        raise RuntimeError(
            f"Found instantiation of '{dut_module}' but no named port connections. "
            "The port checker currently requires named association (e.g. .clk(clk))."
        )
    return formals


def _extract_dut_module_ports(dut_files: List[Path],
                              dut_module: str = DEFAULT_DUT_MODULE) -> List[str]:
    """
    Scan the DUT source files and return the list of port names appearing
    in the module header for 'dut_module'.
    """
    combined = ""
    for p in dut_files:
        try:
            combined += p.read_text(encoding="utf-8") + "\n"
        except Exception:
            continue

    mod_re = re.compile(
        rf"module\s+{dut_module}\b"
        r"(?:\s*#\s*\([^;]*\))?\s*"  # optional parameter block
        r"\((?P<ports>[^;]*?)\)\s*;",
        re.S,
    )
    m = mod_re.search(combined)
    if not m:
        raise RuntimeError(
            f"Could not find a module definition for '{dut_module}' in DUT sources."
        )

    port_block = m.group("ports")
    port_block = re.sub(r"//.*", "", port_block)

    ports: List[str] = []
    for chunk in port_block.split(","):
        t = chunk.strip()
        if not t:
            continue
        t = re.split(r"/\*", t)[0].strip()
        t = re.sub(r"\[[^\]]+\]", " ", t)
        words = t.split()
        if not words:
            continue
        ports.append(words[-1])
    return ports


def _collect_dut_modules(dut_files: List[Path]) -> Dict[str, List[str]]:
    """
    Scan DUT sources and return a mapping of module name -> port list.
    """
    combined = ""
    for p in dut_files:
        try:
            combined += p.read_text(encoding="utf-8") + "\n"
        except Exception:
            continue

    modules: Dict[str, List[str]] = {}
    mod_re = re.compile(
        r"module\s+(?P<name>\w+)\b"
        r"(?:\s*#\s*\([^;]*\))?\s*"
        r"\((?P<ports>[^;]*?)\)\s*;",
        re.S,
    )
    for m in mod_re.finditer(combined):
        name = m.group("name")
        port_block = m.group("ports")
        port_block = re.sub(r"//.*", "", port_block)
        ports: List[str] = []
        for chunk in port_block.split(","):
            t = chunk.strip()
            if not t:
                continue
            t = re.split(r"/\*", t)[0].strip()
            t = re.sub(r"\[[^\]]+\]", " ", t)
            words = t.split()
            if not words:
                continue
            ports.append(words[-1])
        if name and name not in modules:
            modules[name] = ports
    return modules


def _extract_tb_instantiation(tb_text: str) -> Tuple[str, List[str]]:
    """
    Find the first named-port instantiation and return (module_name, port_list).
    """
    inst_re = re.compile(
        r"(?P<mod>\w+)\s*"
        r"(?:#\s*\([^;]*?\)\s*)?"
        r"\w+\s*\((?P<ports>[^;]*?)\)\s*;",
        re.S,
    )
    for m in inst_re.finditer(tb_text):
        port_block = m.group("ports")
        formals = re.findall(r"\.(\w+)\s*\(", port_block)
        if formals:
            return m.group("mod"), formals
    raise RuntimeError("Could not find a named-port instantiation in TB.")


def _replace_tb_inst_module(tb_text: str, old: str, new: str) -> str:
    inst_re = re.compile(
        rf"\b{re.escape(old)}\b(\s*(?:#\s*\([^;]*?\)\s*)?\w+\s*\([^;]*?\)\s*;)",
        re.S,
    )
    return inst_re.sub(new + r"\1", tb_text, count=1)


def auto_resolve_dut_module(tb_text: str,
                            dut_files: List[Path],
                            preferred: str) -> Tuple[str, str, bool]:
    """
    If TB-instantiated module isn't found in DUT sources, try to auto-select
    the correct module and rewrite the instantiation.
    Returns (tb_text, dut_module_name, resolved_ok).
    """
    modules = _collect_dut_modules(dut_files)
    if not modules:
        return tb_text, preferred, False

    if preferred in modules:
        return tb_text, preferred, True

    try:
        tb_mod, tb_ports = _extract_tb_instantiation(tb_text)
    except RuntimeError:
        tb_mod = preferred
        tb_ports = []

    if tb_mod in modules:
        return tb_text, tb_mod, True

    # If only one module exists, use it.
    if len(modules) == 1:
        only = next(iter(modules.keys()))
        return _replace_tb_inst_module(tb_text, tb_mod, only), only, True

    # Try to match by port list
    if tb_ports:
        tb_set = set(tb_ports)
        exact = [m for m, ports in modules.items() if set(ports) == tb_set]
        if len(exact) == 1:
            m = exact[0]
            return _replace_tb_inst_module(tb_text, tb_mod, m), m, True
        sup = [m for m, ports in modules.items() if tb_set.issubset(set(ports))]
        if len(sup) == 1:
            m = sup[0]
            return _replace_tb_inst_module(tb_text, tb_mod, m), m, True

    return tb_text, preferred, False


def check_dut_ports_against_tb(tb_text: str,
                               dut_files: List[Path],
                               dut_module: str = DEFAULT_DUT_MODULE,
                               allow_missing: bool = False) -> None:
    """
    Compare the port list implied by the TB's DUT instantiation against the
    port list in the DUT module header. Abort early if they differ.
    """
    if not dut_files:
        return

    try:
        tb_ports = _extract_tb_dut_ports(tb_text, dut_module)
        dut_ports = _extract_dut_module_ports(dut_files, dut_module)
    except RuntimeError as e:
        print(f"[generate_tb] DUT/TB port-check error: {e}")
        if allow_missing or os.getenv("TB_PORTCHECK_ALLOW_MISSING", "0") == "1":
            print("[generate_tb] Skipping DUT/TB port-check (allow_missing).")
            return
        raise SystemExit("[generate_tb] Aborting due to DUT/TB port-check failure.")

    tb_set = set(tb_ports)
    dut_set = set(dut_ports)

    missing_in_dut = tb_set - dut_set
    extra_in_dut   = dut_set - tb_set

    ok = True
    if missing_in_dut or extra_in_dut or (len(tb_ports) != len(dut_ports)):
        ok = False

    if not ok:
        print("[generate_tb] ERROR: DUT/TB port mismatch detected BEFORE compilation.")
        print(f"  TB  ports ({len(tb_ports)}):  {', '.join(tb_ports)}")
        print(f"  DUT ports ({len(dut_ports)}):  {', '.join(dut_ports)}")
        if missing_in_dut:
            print("  Ports driven by TB but missing in DUT: "
                  + ", ".join(sorted(missing_in_dut)))
        if extra_in_dut:
            print("  Ports present in DUT but not used by TB: "
                  + ", ".join(sorted(extra_in_dut)))
        raise SystemExit("[generate_tb] Aborting because DUT ports do not match TB ports.")
    else:
        print("[generate_tb] DUT/TB port check: interfaces match.")


def emit_auto_stub_dut(out_dir: Path, data_w: int, addr_w: int) -> Path:
    """
    Writes a minimal synchronous SRAM controller named 'sram_sync_ctrl' that matches the TB ports:
      clk, rstn, req, we, addr[ADDR_W-1:0], wdata[DATA_W-1:0], be[DATA_W/8-1:0], rdata[DATA_W-1:0], rvalid
    Behavior:
      - On req & we, write occurs immediately (byte-enable respected).
      - On req & !we, read occurs with 1-cycle latency; rvalid pulses for 1 cycle.
    This is intentionally simple and Icarus-friendly.
    """
    be_w = max(1, data_w // 8)
    text = f"""
// Auto-generated stub DUT: synchronous SRAM controller
// Note: simple model for compilation & basic TB checks; not cycle-accurate to any real core.
module sram_sync_ctrl #(
  parameter int DATA_W = {data_w},
  parameter int ADDR_W = {addr_w}
) (
  input  logic                 clk,
  input  logic                 rstn,
  input  logic                 req,
  input  logic                 we,
  input  logic [ADDR_W-1:0]    addr,
  input  logic [DATA_W-1:0]    wdata,
  input  logic [{be_w}-1:0]    be,
  output logic [DATA_W-1:0]    rdata,
  output logic                 rvalid
);
  localparam int BE_W = (DATA_W/8>0)?(DATA_W/8):1;
  localparam int DEPTH = (1 << ADDR_W);

  logic [DATA_W-1:0] mem [0:DEPTH-1];

  // one-cycle read latency
  logic                 rd_pipe;
  logic [ADDR_W-1:0]    addr_d;

  integer i;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      rdata   <= '0;
      rvalid  <= 1'b0;
      rd_pipe <= 1'b0;
      addr_d  <= '0;
    end else begin
      rvalid  <= rd_pipe;
      rd_pipe <= 1'b0;

      // write on req & we
      if (req && we) begin
        if (BE_W == 1) begin
          if (be[0]) mem[addr] <= wdata;
        end else begin
          logic [DATA_W-1:0] cur;
          cur = mem[addr];
          for (i = 0; i < BE_W; i++) begin
            if (be[i]) begin
              cur[i*8 +: 8] = wdata[i*8 +: 8];
            end
          end
          mem[addr] <= cur;
        end
      end

      // schedule read on req & !we
      if (req && !we) begin
        addr_d  <= addr;
        rd_pipe <= 1'b1;
      end

      if (rd_pipe) begin
        rdata <= mem[addr_d];
      end
    end
  end
endmodule
"""
    path = out_dir / "auto_stub_dut.sv"
    write(path, text.strip() + "\n")
    return path

# ---------- main ----------

def main():
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True, help="Path to spec.json from the front-end")
    ap.add_argument("--out", default=str(RUNNER_DIR / "build" / "tb_gen.sv"))
    ap.add_argument("--engineer-model", default=os.getenv("TB_ENGINEER_MODEL", os.getenv("LLM_MODEL", "protected.gpt-5")))
    ap.add_argument("--checker-model", default=os.getenv("TB_CHECKER_MODEL", os.getenv("LLM_MODEL", "protected.gpt-5")))
    ap.add_argument("--template", default="", help="Override: explicit path to tb_template.sv")
    ap.add_argument("--max-iters", type=int, default=int(os.getenv("TB_CHECKER_MAX_ITERS", "10")))
    # DUT directory argument (default: ROOT_DIR / "DUT")
    ap.add_argument("--dut-dir", default=str(ROOT_DIR / "DUT"),
                    help="Directory containing DUT .sv files (default: ROOT_DIR/DUT)")
    args = ap.parse_args()


    spec_path = Path(args.spec).resolve()
    if not spec_path.exists():
        raise SystemExit(f"Spec not found: {spec_path}")

    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    kind = spec.get("kind")
    if not kind:
        raise SystemExit("Spec is missing 'kind'.")

    # Choose template
    if args.template:
        tpl_path = Path(args.template).resolve()
        if not tpl_path.exists():
            raise SystemExit(f"Template not found: {tpl_path}")
    else:
        tpl_path = resolve_template_for_kind(kind)
        if tpl_path is None or not tpl_path.exists():
            opts_list = [str(p) for p in available_template_dirs()]

            opts = ("\n  - " + "\n  - ".join(opts_list)) if opts_list else "\n  (none found)"
            raise SystemExit(
                f"No template found for kind='{kind}'.\n"
                f"Looked under: {TPL_DIR}\n"
                f"Available template folders (each has tb_template.sv):{opts}\n"
                f"Hint: pass --template <path-to-tb_template.sv>"
            )

    print(f"[generate_tb] LLM_PROVIDER={os.getenv('LLM_PROVIDER','<unset>')}")
    print(f"[generate_tb] spec loaded from {spec_path.name}; kind='{kind}'")
    print(f"[generate_tb] template={tpl_path}")

    # 1) Load and fill placeholders
    template_text = read(tpl_path)
    template_text = render_placeholders(template_text, spec)

    # 2) STAGED PIPELINE: engineer fills one slice, checker stabilizes, then proceed.
    tb_current = template_text
    engineer = TamusAdapter(model=args.engineer_model)
    stage_summaries: List[Dict[str, Any]] = []
    stage_failed = False

    stage_retry_max = int(os.getenv("TB_STAGE_RETRY_MAX", "2"))

    for stage_idx, region_group in enumerate(SLICE_PLAN, start=1):
        print(f"[stage {stage_idx}] BEGIN slice, requested regions={region_group}")

        # Peek at which @LLM_EDIT regions actually exist in the current TB
        scan_engine = GuardedEditEngine(provider=engineer)
        all_regions = scan_engine._find_regions(tb_current)  # type: ignore[attr-defined]
        present_names = [r.name for r in all_regions if r.name in region_group]

        if not present_names:
            # Nothing to do in this stage for this template
            print(f"[stage {stage_idx}] no matching @LLM_EDIT regions found; skipping engineer/checker.")
            stage_summaries.append({
                "stage": stage_idx,
                "regions": region_group,
                "approved": True,
                "skipped": True,
                "note": "no matching @LLM_EDIT regions in template",
            })
            print(f"[stage {stage_idx}] END (skipped)")
            continue

        tb_stage_base = tb_current
        extra_tasks: List[str] = []
        for attempt in range(1, stage_retry_max + 1):
            print(f"[stage {stage_idx}] engineer filling regions actually present: {present_names}")
            print(f"[stage {stage_idx}] contacting LLM engineer...", flush=True)
            tb_current = apply_slice(
                tb_stage_base,
                spec,
                engineer,
                include_regions=region_group,
                extra_tasks=extra_tasks,
            )

            print(f"[stage {stage_idx}] checker loop starting...")
            tb_stage, meta = run_checker_loop(
                tb_current,
                spec,
                args.checker_model,
                args.max_iters,
                allowed_regions=present_names,
            )
            tb_stage = icarus_fixups(tb_stage)  # automatic compile-oriented fixes
            tb_current = tb_stage

            stage_meta = {"stage": stage_idx, "regions": region_group, "attempt": attempt}
            stage_meta.update(meta)
            stage_summaries.append(stage_meta)

            print(f"[stage {stage_idx}] approved={meta.get('approved')}")
            for h in meta.get("history", []):
                print(
                    f"  - iter {h.get('iter')}: "
                    f"verdict={h.get('verdict')} "
                    f"reasons={'; '.join(h.get('reasons', [])) or '(none)'} "
                    f"edits_applied={h.get('edits_applied')}"
                )

            if meta.get("approved", False):
                print(f"[stage {stage_idx}] END (approved)")
                break

            # Auto-repair: roll back to last stable TB and retry with extra context.
            last_reasons = []
            for h in meta.get("history", []):
                last_reasons = h.get("reasons", []) or last_reasons
            extra_tasks = _derive_retry_tasks(last_reasons, present_names)
            tb_current = tb_stage_base

        if not meta.get("approved", False):
            print(f"[stage {stage_idx}] ERROR: slice not approved. Halting staged generation.")
            print(f"[stage {stage_idx}] END (not approved)")
            stage_failed = True
            break

    out_path = Path(args.out)
    out_dir = out_path.parent

    if stage_failed:
        write(out_path, tb_current)
        print(f"[generate_tb] wrote partial TB -> {out_path}  (size={len(tb_current)} bytes)")
        raise SystemExit("[generate_tb] Aborting: staged generation failed.")

    # 3) Final whole-file checker pass
    print("[final] whole-file checker pass...")
    tb_final, meta_final = run_checker_loop(tb_current, spec, args.checker_model, args.max_iters)
    tb_final = icarus_fixups(tb_final)  # final safety pass
    for h in meta_final.get("history", []):
        print(f"  - iter {h.get('iter')}: verdict={h.get('verdict')} reasons={'; '.join(h.get('reasons', [])) or '(none)'} edits_applied={h.get('edits_applied')}")
    approved = meta_final.get("approved", False)

    # 4) Write TB
    write(out_path, tb_final)
    print(f"[generate_tb] wrote -> {out_path}  (size={len(tb_final)} bytes)")

    if not approved:
        raise SystemExit("[generate_tb] Aborting: final checker did not approve.")

    # 4.5) syntax pre-check with Icarus (TB alone, DUT inst commented out)
    syntax_fix_max = int(os.getenv("TB_SYNTAX_FIX_MAX_ITERS", "3"))
    syntax_provider = TamusAdapter(model=args.checker_model)
    for attempt in range(1, syntax_fix_max + 1):
        ok, out = icarus_syntax_check(out_path)
        if ok:
            break
        print(f"[generate_tb] syntax fix attempt {attempt}/{syntax_fix_max}", flush=True)
        tb_text = out_path.read_text(encoding="utf-8")
        edits = _syntax_fix(tb_text, out, syntax_provider)
        if not edits:
            raise SystemExit("[generate_tb] Aborting: syntax fix returned no edits.")
        tb_text, applied = apply_edits(tb_text, edits)
        if applied == 0:
            raise SystemExit("[generate_tb] Aborting: syntax fix edits did not apply.")
        tb_text = icarus_fixups(tb_text)
        write(out_path, tb_text)
    else:
        raise SystemExit("[generate_tb] Aborting: Icarus syntax check failed after retries.")

    # 5) Collect DUT files (preferred) or auto-emit stub DUT as fallback
    dut_dir = Path(args.dut_dir).resolve()
    dut_files = collect_dut_files(dut_dir)
    auto_stub_path: Optional[Path] = None

    # check DUT ports vs TB ports before compile/sim
    if dut_files:
        dut_module_name = (
            str(spec.get("dut_module", "")).strip()
            or os.getenv("TB_DUT_MODULE", "").strip()
            or DEFAULT_DUT_MODULE
        )
        tb_final_before = tb_final
        tb_final, resolved_module, resolved_ok = auto_resolve_dut_module(
            tb_final, dut_files, dut_module_name
        )
        if tb_final != tb_final_before:
            write(out_path, tb_final)
        if resolved_ok and resolved_module != dut_module_name:
            print(f"[generate_tb] Auto-resolved DUT module: {resolved_module} (was {dut_module_name})")
            dut_module_name = resolved_module
        print(f"[generate_tb] DUT module for port-check: {dut_module_name}")
        check_dut_ports_against_tb(
            tb_final,
            dut_files,
            dut_module=dut_module_name,
            allow_missing=not resolved_ok,
        )

    if dut_files:
        print(f"[generate_tb] Using DUT files from {dut_dir}:")
        for f in dut_files:
            print(f"  - {f}")
        print("[generate_tb] Skipping auto stub DUT because explicit DUT sources were found.")
    else:
        if os.getenv("NO_AUTO_STUB", "0") != "1":
            # If the checker already injected a 'sram_sync_ctrl' module into tb_final,
            # don't emit a second stub or we'll get a duplicate-module error.
            if re.search(r"\bmodule\s+sram_sync_ctrl\b", tb_final):
                print("[generate_tb] Inline sram_sync_ctrl definition detected in tb_gen.sv; skipping auto stub DUT.")
            else:
                data_w = int(spec.get("data_width", 32))
                addr_w = int(spec.get("addr_width", 16))
                dut_dir.mkdir(parents=True, exist_ok=True)
                auto_stub_path = emit_auto_stub_dut(dut_dir, data_w, addr_w)
                print(f"[generate_tb] wrote auto stub DUT -> {auto_stub_path}")
        else:
            print("[generate_tb] NO_AUTO_STUB=1 and no DUT files found; relying on manual stub if present.")

    # 6) Emit a minimal filelist for iverilog (relative paths to avoid spaces)
    filelist_path = out_dir / "filelist.f"

    incdir_lines: list[str] = []
    files: list[str] = []

    # Testbench first (relative to ROOT_DIR)
    files.append(rel_to_root(out_path))

    if dut_files:
        # For include files like `ddr2_timing_params.svh` in DUT
        incdir_lines.append(" +incdir+DUT")
        # Add each DUT .sv file by relative path
        for f in dut_files:
            files.append(rel_to_root(f))
    else:
        # Old stub behavior if no DUT files
        manual_stub = (RUNNER_DIR / "stub_dut.sv")
        if manual_stub.exists():
            files.append(rel_to_root(manual_stub))
        if auto_stub_path and auto_stub_path.exists():
            files.append(rel_to_root(auto_stub_path))

    # ONLY Icarus-safe models per kind (leave DDR/DDR2 out)
    kind_to_icarus_models: Dict[str, List[str]] = {
        "sram_controller": [],
        "fifo_controller": [],
        "rom_controller":  [],
    }
    for rel in kind_to_icarus_models.get(kind, []):
        files.append(rel_to_root(ROOT_DIR / rel))

    filelist_contents = ""
    if incdir_lines:
        filelist_contents += "\n".join(incdir_lines) + "\n"
    filelist_contents += "\n".join(files) + "\n"

    write(filelist_path, filelist_contents)
    print(f"[generate_tb] wrote filelist -> {filelist_path}")


if __name__ == "__main__":
    main()
