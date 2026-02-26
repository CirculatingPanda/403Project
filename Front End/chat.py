# chat.py — Front-end console + Qt GUI chat for TAMU AI Chat API
from pathlib import Path
import os, sys, json, copy, re
from difflib import SequenceMatcher
from typing import List, Dict
from datetime import datetime

import requests
from dotenv import load_dotenv, find_dotenv
from rich.console import Console
from rich.panel import Panel
from prompt_toolkit import PromptSession
from prompt_toolkit.history import InMemoryHistory
import tiktoken

# ---------- Qt GUI imports (PySide6) ----------
try:
    from PySide6.QtWidgets import (
        QApplication,
        QWidget,
        QVBoxLayout,
        QHBoxLayout,
        QTextEdit,
        QLineEdit,
        QPushButton,
        QLabel,
        QProgressBar,
        QFileDialog,
    )
    from PySide6.QtCore import Qt
    QT_AVAILABLE = True
except ImportError:
    QT_AVAILABLE = False

# ----------------------
# Environment & Client
# ----------------------
load_dotenv(find_dotenv())

ENDPOINT = os.getenv("TAMUS_AI_CHAT_API_ENDPOINT", "https://chat-api.tamu.ai")
API_KEY  = os.getenv("TAMUS_AI_CHAT_API_KEY")
MODEL    = os.getenv("TAMUS_AI_MODEL", "protected.gpt-5")

if not API_KEY:
    print("Missing TAMUS_AI_CHAT_API_KEY. Put it in .env or your shell env.")
    sys.exit(1)

BASE_URL = ENDPOINT.rstrip("/") + "/api"

S = requests.Session()
S.headers.update({
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
})

console = Console()
session = PromptSession(history=InMemoryHistory())

SYSTEM_MSG = (
    "You help a hardware engineer complete a JSON specification for on-chip memory controllers.\n"
    "Always follow any [GUIDANCE] block in the latest user turn.\n"
    "Style:\n"
    "• Start each new-field prompt with 'Next field:' on its own line.\n"
    "• Start each acknowledgment with '✅ Set <field> to <value>.' on its own line.\n"
    "Rules:\n"
    "• Ask only for fields that appear in ask_order for the active kind.\n"
    "• If the kind is missing, request the user pick exactly one from the provided list.\n"
    "• For categorical fields (marked as 'word/option' in GUIDANCE), ask the user to 'Type a word/option'.\n"
    "• If the user types 'default' and a default exists, use that concrete value and emit it in UPDATE_JSON (never the literal string 'default').\n"
    "• After the user answers, acknowledge exactly with '✅ Set <field> to <value>.' then on a new line emit:\n"
    '  UPDATE_JSON={\"path\":\"<field.path>\",\"value\":<json_value>}\n'
    "• The <field.path> MUST be the canonical dotted path (e.g., reset.sync, host_if.endian), not a friendly label.\n"
    "• When every required field is filled, present the compact final JSON specification and note where it was saved."
)

# --- Registry load ---
REG_PATH = os.path.join(os.getcwd(), "spec_registry.json")
try:
    with open(REG_PATH, "r", encoding="utf-8") as f:
        REGISTRY = json.load(f)
except FileNotFoundError:
    console.print("[red]spec_registry.json not found.[/red]")
    sys.exit(1)

# ----------------------
# Path helpers & registry accessors
# ----------------------
def new_spec(kind: str) -> dict:
    return copy.deepcopy(REGISTRY["kinds"][kind]["skeleton"])

def ask_order(kind: str) -> list:
    return REGISTRY["kinds"][kind]["ask_order"]

def default_for(kind: str, path: str):
    return REGISTRY["kinds"][kind]["defaults"].get(path)

def get_by_path(d: dict, path: str):
    cur = d
    for k in path.split("."):
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur

def set_by_path(d: dict, path: str, value):
    cur = d
    parts = path.split(".")
    for k in parts[:-1]:
        if k not in cur or not isinstance(cur[k], dict):
            cur[k] = {}
        cur = cur[k]
    cur[parts[-1]] = value

def next_missing_field(kind: str, spec: dict) -> str | None:
    for p in ask_order(kind):
        v = get_by_path(spec, p)
        if v in (None, "", []):
            return p
    return None

def next_missing_after(kind: str, spec: dict, current_path: str | None) -> str | None:
    found = False
    for p in ask_order(kind):
        if p == current_path:
            found = True
            continue
        if not found:
            continue
        v = get_by_path(spec, p)
        if v in (None, "", []):
            return p
    return None

def normalize_path(path: str | None) -> str | None:
    if path is None:
        return None
    p = path.strip()
    # Map friendly label back to canonical path if possible
    try:
        if p in FRIENDLY_TO_CANON:
            return FRIENDLY_TO_CANON[p]
        pl = p.lower()
        if pl in FRIENDLY_TO_CANON:
            return FRIENDLY_TO_CANON[pl]
    except Exception:
        pass
    # Common aliases the model sometimes emits
    alias = {
        "reset.synchronous": "reset.sync",
        "reset_sync": "reset.sync",
        "reset synchronous": "reset.sync",
        "host endianness": "host_if.endian",
        "host_if.endianness": "host_if.endian",
    }
    if p in alias:
        return alias[p]
    pl = p.lower()
    if pl in alias:
        return alias[pl]
    while p.startswith("/"):
        p = p[1:]
    p = p.replace("/", ".")
    return p

def valid_path_for_kind(kind: str, path: str) -> bool:
    if path == "kind":
        return True
    return path in ask_order(kind)

# ----------------------
# Field types (MOVED UP so LLM parsing can reference it)
# ----------------------
FIELD_TYPE = {
    # categorical “word/option”
    "host_if.bus": "word",
    "ecc.scheme": "word",
    "dram.row_policy": "word",
    "scheduler.policy": "word",
    "conflicts.same_address": "word",
    "fifo.iface": "word",
    "regfile.hazard_policy": "word",
    "behavior.on_overflow": "word",
    "behavior.on_underflow": "word",
    "init.type": "word",
    "init.source": "word",
    "sram.read_mode": "word",
    "sram.write_mode": "word",

    # booleans
    "ecc.enabled": "boolean",
    "write_enable_mask": "boolean",
    "regfile.bypass_on_same_cycle": "boolean",
    "fifo.fwft": "boolean",
    "init.required": "boolean",

    # numbers
    "host_if.data_bits": "number",
    "host_if.addr_bits": "number",
    "mem.data_bits": "number",
    "mem.depth": "number",
    "timing.read_latency_cycles": "number",
    "clock_mhz": "number",
    "dram.row_bits": "number",
    "dram.col_bits": "number",
    "dram.bank_bits": "number",
    "dram.burst_len": "number",
    "timing.tRCD": "number",
    "timing.tCL": "number",
    "timing.tRP": "number",
    "timing.tRAS": "number",
    "timing.tRC": "number",
    "timing.tWR": "number",
    "timing.tWTR": "number",
    "timing.tRTP": "number",
    "timing.tFAW": "number",
    "refresh.period_ns": "number",
    "regfile.entries": "number",
    "regfile.data_bits": "number",
    "regfile.read_ports": "number",
    "regfile.write_ports": "number",
    "fifo.data_bits": "number",
    "fifo.depth": "number",
    "sram.setup_cycles": "number",
    "sram.hold_cycles": "number",
    "sram.gap_cycles": "number",
    "byte_enable_granularity": "number",
    "fifo.almost_full_thresh": "number",
    "fifo.almost_empty_thresh": "number",
}

def field_kind(path: str) -> str:
    return FIELD_TYPE.get(path, "value")

# ----------------------
# Friendly names (AUTO-GENERATED from registry + overrides)
# ----------------------
def iter_leaf_paths(obj, prefix=""):
    """Yield dotted paths for every leaf in a nested dict."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            newp = f"{prefix}.{k}" if prefix else k
            yield from iter_leaf_paths(v, newp)
    else:
        yield prefix

def auto_friendly_label(path: str) -> str:
    """
    Reasonable default label from a dotted path.
    Keep tRCD/tCL/etc case as-is.
    """
    s = path.replace(".", " ").replace("_", " ")
    s = s.replace("host if", "host")
    s = s.replace("mem ", "memory ")
    s = s.replace("dram ", "DRAM ")
    s = s.replace("ecc ", "ECC ")
    s = s.replace("phy ", "PHY ")
    return s.strip()

def build_friendly_names_from_registry(registry: dict) -> dict:
    names = {}
    for _kind, meta in registry.get("kinds", {}).items():
        skel = meta.get("skeleton", {})
        for p in iter_leaf_paths(skel):
            names.setdefault(p, auto_friendly_label(p))
        for p in meta.get("ask_order", []):
            names.setdefault(p, auto_friendly_label(p))
        for p in meta.get("defaults", {}).keys():
            names.setdefault(p, auto_friendly_label(p))
    return names

FRIENDLY_NAMES = build_friendly_names_from_registry(REGISTRY)

FRIENDLY_OVERRIDES = {
    # common
    "kind": "kind",
    "name": "name",
    "description": "description",
    "clock_mhz": "clock (MHz)",

    # reset
    "reset.active_low": "reset active low",
    "reset.sync": "synchronous reset",

    # host interface (single)
    "host_if.bus": "host bus",
    "host_if.data_bits": "host data bits",
    "host_if.addr_bits": "host address bits",
    "host_if.endian": "host endianness",

    # dualport host_if
    "host_if.portA.bus": "host port A bus",
    "host_if.portA.data_bits": "host port A data bits",
    "host_if.portA.addr_bits": "host port A address bits",
    "host_if.portA.endian": "host port A endianness",
    "host_if.portB.bus": "host port B bus",
    "host_if.portB.data_bits": "host port B data bits",
    "host_if.portB.addr_bits": "host port B address bits",
    "host_if.portB.endian": "host port B endianness",

    # memory
    "mem.data_bits": "memory data bits",
    "mem.depth": "memory depth",

    # FIFO
    "fifo.depth": "FIFO depth",
    "fifo.data_bits": "FIFO data bits",
    "fifo.almost_full_thresh": "FIFO almost-full threshold",
    "fifo.almost_empty_thresh": "FIFO almost-empty threshold",
    "fifo.iface": "FIFO interface",
    "behavior.on_overflow": "overflow behavior",
    "behavior.on_underflow": "underflow behavior",

    # ROM init
    "init.type": "init type",
    "init.source": "init source",

    # regfile
    "regfile.entries": "register file entries",
    "regfile.data_bits": "register file data bits",
    "regfile.read_ports": "register file read ports",
    "regfile.write_ports": "register file write ports",
    "regfile.bypass_on_same_cycle": "bypass on same cycle",
    "regfile.hazard_policy": "hazard policy",

    # timing
    "timing.read_latency_cycles": "read latency (cycles)",
    "timing.tRCD": "tRCD (activate→read)",
    "timing.tCL": "tCL / CAS latency",
    "timing.tRP": "tRP (precharge)",
    "timing.tRAS": "tRAS (active time)",
    "timing.tRC": "tRC (row cycle)",
    "timing.tWR": "tWR (write recovery)",
    "timing.tWTR": "tWTR (write→read)",
    "timing.tRTP": "tRTP (read→precharge)",
    "timing.tFAW": "tFAW (four activate window)",

    # DRAM params
    "dram.tech": "DRAM technology",
    "dram.row_bits": "DRAM row bits",
    "dram.col_bits": "DRAM column bits",
    "dram.bank_bits": "DRAM bank bits",
    "dram.burst_len": "DRAM burst length",
    "dram.row_policy": "DRAM row policy",
    "dram.dqs": "DQS enabled",
    "dram.odt": "ODT enabled",
    "dram.dll_enable": "DLL enabled",

    # refresh/scheduler/phy
    "refresh.period_ns": "refresh period (ns)",
    "refresh.per_rows": "refresh rows",
    "scheduler.policy": "scheduler policy",
    "phy.read_dqs_gate": "read DQS gate",
    "phy.write_leveling": "write leveling",

    # ECC
    "ecc.enabled": "ECC enabled",
    "ecc.scheme": "ECC scheme",

    # misc
    "write_enable_mask": "write enable mask",
    "chip_selects": "chip selects",
    "conflicts.same_address": "same-address conflict policy",
}
FRIENDLY_NAMES.update(FRIENDLY_OVERRIDES)
FRIENDLY_TO_CANON = {v: k for k, v in FRIENDLY_NAMES.items()}
FRIENDLY_TO_CANON.update({v.lower(): k for k, v in FRIENDLY_NAMES.items()})

def pretty_field(path: str) -> str:
    """Human-readable field name for logs / UI."""
    return FRIENDLY_NAMES.get(path, path)

def describe_field(path: str) -> str:
    # Centralize on friendly names now
    return pretty_field(path)

def user_label_for_path(path: str) -> str:
    return pretty_field(path)

def canon_with_friendly(path: str) -> str:
    return f"{path} ({describe_field(path)})"

def rewrite_user_visible_paths(text: str) -> str:
    """
    Rewrite user-visible occurrences of canonical field paths into friendly names,
    without breaking UPDATE_JSON lines (those must stay canonical).
    """
    if not text:
        return text

    out_lines = []
    for line in text.splitlines():
        if line.startswith("UPDATE_JSON="):
            out_lines.append(line)
            continue

        # Replace the specific "✅ Set <field> to <value>." pattern
        m = re.match(r"^✅ Set\s+(.+?)\s+to\s+(.+?)\.\s*$", line)
        if m:
            raw_field = m.group(1).strip()
            val = m.group(2).strip()
            nice_field = user_label_for_path(raw_field) if raw_field != "kind" else "kind"
            out_lines.append(f"✅ Set {nice_field} to {val}.")
            continue

        line = re.sub(
            r"(Confirm field:\s*)([A-Za-z0-9_.-]+)",
            lambda mm: mm.group(1) + user_label_for_path(mm.group(2)),
            line
        )
        line = re.sub(
            r"(Ask for field:\s*)([A-Za-z0-9_.-]+)",
            lambda mm: mm.group(1) + user_label_for_path(mm.group(2)),
            line
        )
        line = re.sub(
            r"(✅ Set\s+)([A-Za-z0-9_.-]+)(\s+to\s+<value>\.)",
            lambda mm: mm.group(1) + user_label_for_path(mm.group(2)) + mm.group(3),
            line
        )
        out_lines.append(line)

    return "\n".join(out_lines)

def check_friendly_coverage():
    missing = []
    for kind, meta in REGISTRY.get("kinds", {}).items():
        for p in meta.get("ask_order", []):
            if p not in FRIENDLY_NAMES:
                missing.append((kind, p))
        for p in iter_leaf_paths(meta.get("skeleton", {})):
            if p not in FRIENDLY_NAMES:
                missing.append((kind, p))
    if missing:
        console.print("[yellow]Missing FRIENDLY_NAMES entries:[/yellow]")
        for k, p in missing[:50]:
            console.print(f"  {k}: {p}")
        console.print(f"[yellow]Total missing: {len(missing)}[/yellow]")

check_friendly_coverage()

# ----------------------
# Validation
# ----------------------
def _iter_spec_leaves(obj, prefix=""):
    if isinstance(obj, dict):
        for key, val in obj.items():
            new_prefix = f"{prefix}.{key}" if prefix else key
            yield from _iter_spec_leaves(val, new_prefix)
    else:
        yield prefix, obj

def validate_spec(kind: str, spec: dict) -> List[tuple[str, str]]:
    """
    Return a list of (path, reason) validation errors for the current spec.
    Uses FIELD_TYPE to enforce basic type constraints.
    """
    errors: List[tuple[str, str]] = []

    for path, value in _iter_spec_leaves(spec):
        if value in (None, "", []):
            continue

        if isinstance(value, str) and value.strip().lower() == "default":
            errors.append((path, "Replace 'default' with an explicit value."))
            continue

        fkind = field_kind(path)  # "number", "boolean", "word", "value"

        if fkind == "number":
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                errors.append(
                    (path,
                     f"Expected a numeric value (e.g. 32, 4096), "
                     f"not {value!r}.")
                )

        elif fkind == "boolean":
            if not isinstance(value, bool):
                errors.append((path, f"Expected a boolean true/false value, not {value!r}."))

        elif fkind == "word":
            if not isinstance(value, str) or not value.strip():
                errors.append((path, f"Expected a single word/option string, not {value!r}."))

        # Simple domain sanity checks for common numeric fields
        if path in ("host_if.data_bits", "mem.data_bits", "mem.depth", "host_if.addr_bits"):
            if isinstance(value, (int, float)):
                iv = int(value)
                if iv <= 0 or iv != value:
                    errors.append((path, f"{path} must be a positive integer (got {value!r})."))

    return errors

# ----------------------
# Kind inference
# ----------------------
QUESTION_WORDS = {
    "who", "what", "when", "where", "why", "how", "are", "is", "did",
    "does", "do", "can", "should", "could", "would", "will"
}

def is_meta_question(text: str) -> bool:
    stripped = text.strip().lower()
    if not stripped:
        return False
    if "?" in stripped:
        return True
    first_token = stripped.split()[0]
    return first_token in QUESTION_WORDS

_WORD_SYNONYM_SEQUENCES = {
    "dualport": [["dual", "port"], ["dual", "ports"]],
    "regfile": [["register", "file"], ["reg", "file"]],
    "ddr2": [["ddr", "2"]],
}

def _tokens_from_text(text: str) -> List[str]:
    return re.findall(r"[a-z0-9]+", text.lower())

def _sequence_in_tokens(seq: List[str], tokens: List[str]) -> bool:
    if not seq:
        return True
    t_len = len(tokens)
    for i in range(t_len - len(seq) + 1):
        if tokens[i:i + len(seq)] == seq:
            return True
    return False

def _word_in_tokens(word: str, tokens: List[str], token_set: set[str], joined: str) -> bool:
    if word in token_set:
        return True
    for seq in _WORD_SYNONYM_SEQUENCES.get(word, []):
        if _sequence_in_tokens(seq, tokens):
            return True
    if word in joined:
        return True
    for tok in tokens:
        if abs(len(tok) - len(word)) > 2:
            continue
        if SequenceMatcher(None, word, tok).ratio() >= 0.75:
            return True
    return False

def infer_kind_from_text(text: str) -> str | None:
    tokens = _tokens_from_text(text)
    if not tokens:
        return None
    token_set = set(tokens)
    joined = "".join(tokens)
    best_kind = None
    best_score = 0

    for kind in REGISTRY["kinds"].keys():
        words = [w for w in kind.lower().split("_") if w]
        score = 0
        for word in words:
            if word == "controller":
                if _word_in_tokens(word, tokens, token_set, joined):
                    score += 1
                continue
            if _word_in_tokens(word, tokens, token_set, joined):
                score += 3
            elif word.rstrip("s") in token_set:
                score += 2
        if score > best_score:
            best_score = score
            best_kind = kind

    return best_kind if best_score >= 4 else None

# ----------------------
# Tokenizer approx
# ----------------------
enc = tiktoken.get_encoding("cl100k_base")

def token_estimate(messages: List[Dict]) -> int:
    text = "".join(m["role"] + ":" + m["content"] for m in messages)
    return len(enc.encode(text))

def trim_history(messages: List[Dict], budget: int = 6000) -> List[Dict]:
    base = [messages[0]]
    rest = messages[1:]
    while rest and token_estimate(base + rest) > budget:
        rest.pop(0)
    return base + rest

# ----------------------
# Prompt wording helpers
# ----------------------
def make_prompt_line(kind: str, path: str) -> str:
    kind_tag = field_kind(path)  # 'word' | 'number' | 'boolean' | 'value'
    dflt = default_for(kind, path)

    noun = {
        "word":   "a word/option",
        "number": "a number",
        "boolean":"true or false",
        "value":  "a value",
    }[kind_tag]

    if dflt is None:
        return f"🧩 Next field:\nPlease provide {describe_field(path)}. Type {noun}."
    else:
        shown = dflt if not isinstance(dflt, str) else dflt
        return f"🧩 Next field:\nPlease specify {describe_field(path)}. Type {noun} or type default to use {shown}."

def make_ack_line(path: str, value) -> str:
    val = value
    if isinstance(val, bool):
        val = "true" if val else "false"
    return f"✅ Set {user_label_for_path(path)} to {val}."

# ----------------------
# API response extraction
# ----------------------
def _extract_stream_delta(obj: dict) -> str:
    try:
        ch = obj.get("choices", [{}])[0]
        delta = ch.get("delta", {})
        piece = delta.get("content") or ""
        return piece or ""
    except Exception:
        return ""

def _extract_final_text(obj: dict | str) -> str:
    if isinstance(obj, str):
        return obj.strip()
    if not isinstance(obj, dict):
        return json.dumps(obj, indent=2)
    if "choices" in obj and obj["choices"]:
        c0 = obj["choices"][0]
        if isinstance(c0, dict):
            if "message" in c0 and isinstance(c0["message"], dict) and "content" in c0["message"]:
                return str(c0["message"]["content"])
            if "text" in c0:
                return str(c0["text"])
    if "output_text" in obj and obj["output_text"]:
        return str(obj["output_text"])
    if "output" in obj and obj["output"]:
        parts = obj["output"][0].get("content", [])
        pieces = []
        for p in parts:
            if p.get("type") in ("output_text", "text"):
                t = p.get("text")
                if isinstance(t, dict):
                    pieces.append(t.get("value", ""))
                else:
                    pieces.append(str(t))
        if pieces:
            return "".join(pieces).strip()
    for k in ("response", "result", "message", "content"):
        if k in obj:
            v = obj[k]
            return v if isinstance(v, str) else json.dumps(v, indent=2)
    return json.dumps(obj, indent=2)

# ----------------------
# Chat API calls
# ----------------------
def stream_reply(messages: List[Dict]) -> Dict:
    """
    Streams tokens from TAMU /api/chat/completions (SSE) with a non-stream fallback.
    Prints tokens live via Rich, returns a single assistant message dict.
    """
    url = f"{BASE_URL}/chat/completions"
    payload = {
        "model": MODEL,
        "messages": messages,
        "temperature": 0.2,
        "stream": True,
    }

    try:
        with S.post(url, json=payload, timeout=0, stream=True) as r:
            if r.status_code >= 400:
                raise RuntimeError(r.text)
            content = ""
            for line in r.iter_lines(decode_unicode=True):
                if not line:
                    continue
                if line.startswith("data: "):
                    chunk = line[6:].strip()
                    if chunk == "[DONE]":
                        break
                    try:
                        obj = json.loads(chunk)
                        piece = _extract_stream_delta(obj)
                        if piece:
                            content += piece
                            console.print(piece, end="")
                    except json.JSONDecodeError:
                        pass
            console.print()
            if content:
                return {"role": "assistant", "content": content}
    except Exception:
        pass

    payload["stream"] = False
    r = S.post(url, json=payload, timeout=60)
    if r.status_code >= 400:
        try:
            detail = r.json()
        except Exception:
            detail = r.text
        raise RuntimeError(f"HTTP {r.status_code} from {url}\n{detail}")
    try:
        obj = r.json()
    except Exception:
        text = r.text.strip()
        console.print(text)
        return {"role": "assistant", "content": text}
    text = _extract_final_text(obj)
    console.print(text)
    return {"role": "assistant", "content": text}

def api_chat(messages: List[Dict]) -> Dict:
    """
    Simple non-streaming chat call for the GUI.
    Returns {'role': 'assistant', 'content': text} without printing.
    """
    url = f"{BASE_URL}/chat/completions"
    payload = {
        "model": MODEL,
        "messages": messages,
        "temperature": 0.2,
        "stream": False,
    }
    r = S.post(url, json=payload, timeout=60)
    if r.status_code >= 400:
        try:
            detail = r.json()
        except Exception:
            detail = r.text
        raise RuntimeError(f"HTTP {r.status_code} from {url}\n{detail}")
    try:
        obj = r.json()
    except Exception:
        text = r.text.strip()
        return {"role": "assistant", "content": text}
    text = _extract_final_text(obj)
    return {"role": "assistant", "content": text}

# ----------------------
# LLM-assisted parsing for unstructured uploads
# ----------------------
def llm_parse_unstructured_spec(text: str) -> dict:
    """
    Uses the TAMU chat API to convert free-form text into a dict
    compatible with your spec loader (paths matching ask_order()).
    Returns a dict (possibly partial).
    """
    kinds = list(REGISTRY["kinds"].keys())

    extraction_system = (
        "You are a strict information extraction engine.\n"
        "Return ONLY valid JSON. No markdown. No comments. No trailing commas.\n"
        "If unsure, set fields to null or omit them.\n"
        "Normalize units and typos when obvious (e.g., '200mHz' likely means 200 MHz).\n"
        "Map synonyms to canonical field paths.\n"
    )

    extraction_user = {
        "task": "Extract a memory-controller JSON spec from unstructured text.",
        "allowed_kinds": kinds,
        "field_types": FIELD_TYPE,
        "notes": [
            "Only output fields that belong to ask_order(kind).",
            "If kind is not confidently inferred, set kind to null.",
            "For endianness, use values like 'little' or 'big' if present in text.",
        ],
        "input_text": text,
        "output_format": {
            "kind": "one of allowed_kinds or null",
            "fields": "object mapping canonical path -> parsed value"
        }
    }

    msgs = [
        {"role": "system", "content": extraction_system},
        {"role": "user", "content": json.dumps(extraction_user)}
    ]

    assistant = api_chat(msgs)
    raw = assistant.get("content", "").strip()

    try:
        obj = json.loads(raw)
    except Exception:
        m = re.search(r"\{.*\}\s*$", raw, flags=re.DOTALL)
        if not m:
            return {"_llm_error": "Could not parse JSON from model output", "_raw_model": raw}
        obj = json.loads(m.group(0))

    kind = obj.get("kind")
    fields = obj.get("fields", {})

    out = {}
    if kind in REGISTRY["kinds"]:
        out["kind"] = kind
        allowed = set(ask_order(kind)) | {"kind"}
        if isinstance(fields, dict):
            for path, value in fields.items():
                if path in allowed and value not in (None, "", []):
                    set_by_path(out, path, value)
    else:
        out["_extracted_fields_flat"] = fields if isinstance(fields, dict) else {}
    return out

def parse_spec_file(path: str) -> dict:
    p = Path(path)
    text = p.read_text(encoding="utf-8", errors="ignore").strip()

    if p.suffix.lower() == ".json":
        return json.loads(text)

    if p.suffix.lower() in (".yaml", ".yml"):
        try:
            import yaml
            y = yaml.safe_load(text)
            if isinstance(y, dict):
                return y
        except Exception:
            pass

    # Very small key:value parser
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        k, v = [x.strip() for x in line.split(":", 1)]
        if v.lower() in ("true", "false"):
            v2 = (v.lower() == "true")
        else:
            try:
                v2 = int(v) if re.fullmatch(r"-?\d+", v) else float(v)
            except Exception:
                v2 = v.strip('"').strip("'")
        set_by_path(out, normalize_path(k), v2)

    # If we got nothing useful, ask the model
    if not out:
        out = llm_parse_unstructured_spec(text)

    return out

# ----------------------
# Export
# ----------------------
def sanitize_filename(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", s)

def export_spec_auto(kind: str, spec: dict) -> str:
    ts = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    name = sanitize_filename(spec.get("name") or kind)
    fname = f"{name}_{ts}.json"
    fpath = os.path.join(os.getcwd(), fname)
    with open(fpath, "w", encoding="utf-8") as f:
        json.dump(spec, f, indent=2)
    return fpath

# --------- SpecEngine: original main-loop logic as a reusable engine ----------
class SpecEngine:
    """
    Encapsulates the original console main-loop behavior so it can be driven
    either from the terminal or from a GUI.
    """
    def progress(self) -> tuple[int, int]:
        if not self.current_kind or not self.working_spec:
            return 0, 0
        paths = ask_order(self.current_kind)
        total = len(paths)
        filled = sum(1 for p in paths if get_by_path(self.working_spec, p) not in (None, "", []))
        return filled, total

    def __init__(self):
        self.reset()

    def reset(self):
        self.messages = [{"role": "system", "content": SYSTEM_MSG}]
        self.current_kind = None
        self.working_spec = None
        self.exported_once = False
        self.last_export_path = None
        self.pending_ack_field = None
        self.queued_field_after_ack = None
        self.ignore_update_for_field = None
        self.auto_user_message = None
        self.available_kind_list = list(REGISTRY["kinds"].keys())
        self.available_kinds = ", ".join(self.available_kind_list)
        self.just_set_kind = None

    def handle_user(self, user: str) -> List[str]:
        replies: List[str] = []

        safety = 5
        while self.auto_user_message is not None and safety > 0:
            safety -= 1
            auto = self.auto_user_message
            self.auto_user_message = None
            reply = self._one_turn(auto, use_stream=False)
            if reply:
                replies.append(reply)

        reply = self._one_turn(user, use_stream=False)
        if reply:
            replies.append(reply)

        safety = 5
        while self.auto_user_message is not None and safety > 0:
            safety -= 1
            auto = self.auto_user_message
            self.auto_user_message = None
            reply = self._one_turn(auto, use_stream=False)
            if reply:
                replies.append(reply)

        return replies

    def _one_turn(self, user: str, use_stream: bool = False) -> str:
        user = user.strip()
        if not user:
            return ""

        low = user.lower()

        if low == "/reset":
            self.reset()
            return "Session reset."

        # --- Auto-kind detection ---
        if self.current_kind is None:
            num_match = re.fullmatch(r"\d+", user)
            if num_match:
                idx = int(num_match.group()) - 1
                if 0 <= idx < len(self.available_kind_list):
                    chosen = self.available_kind_list[idx]
                    self.current_kind = chosen
                    self.just_set_kind = chosen
                    self.working_spec = new_spec(chosen)
                    self.exported_once = False
                    self.last_export_path = None
                    self.pending_ack_field = None
                    self.queued_field_after_ack = None
                    self.ignore_update_for_field = None
                    self.auto_user_message = None

        if self.current_kind is None:
            detected = infer_kind_from_text(low)
            if detected:
                self.current_kind = detected
                self.just_set_kind = detected
                self.working_spec = new_spec(detected)
                self.exported_once = False
                self.last_export_path = None
                self.pending_ack_field = None
                self.queued_field_after_ack = None
                self.ignore_update_for_field = None
                self.auto_user_message = None

        if self.current_kind is None:
            guidance = f"Kind not chosen. Available: {self.available_kinds}"
        else:
            missing = next_missing_field(self.current_kind, self.working_spec)
            meta_question = False

            if self.just_set_kind is not None:
                if missing:
                    prompt_line = make_prompt_line(self.current_kind, missing)
                    guidance = (
                        f"Current kind: {self.current_kind}\n"
                        "Kind was just chosen based on the user's last message.\n"
                        f"First, say exactly '✅ Set kind to {self.current_kind}.' on its own line.\n"
                        f"Immediately after, output UPDATE_JSON={{\"path\":\"kind\",\"value\":\"{self.current_kind}\"}} on the next line.\n"
                        f"Then explain in 1–3 short sentences what {describe_field(missing)} represents in the FIFO/DRAM/memory-controller context "
                        "and why it matters for hardware behavior.\n"
                        f"{prompt_line}\n"
                        "Do not ask the user to pick a kind again."
                    )
                    self.pending_ack_field = missing
                    self.queued_field_after_ack = None
                    self.ignore_update_for_field = None
                else:
                    guidance = (
                        f"Current kind: {self.current_kind}\n"
                        f"First, say exactly '✅ Set kind to {self.current_kind}.' on its own line.\n"
                        f"Immediately after, output UPDATE_JSON={{\"path\":\"kind\",\"value\":\"{self.current_kind}\"}} on the next line.\n"
                        "Then show the compact final JSON specification and mention where it was saved."
                    )
                self.just_set_kind = None

            elif self.auto_user_message is None and self.pending_ack_field and is_meta_question(user):
                meta_question = True
                self.ignore_update_for_field = self.pending_ack_field

            if meta_question and self.pending_ack_field:
                field = self.pending_ack_field
                reask_line = make_prompt_line(self.current_kind, field)
                guidance = (
                    f"Current kind: {self.current_kind}\n"
                    "The user asked a side question. Respond briefly to the question without changing any field values.\n"
                    "Do not emit UPDATE_JSON for this turn.\n"
                    f"{reask_line}"
                )

            elif self.pending_ack_field and missing == self.pending_ack_field:
                ack_field = self.pending_ack_field
                next_field = next_missing_after(self.current_kind, self.working_spec, ack_field)
                self.queued_field_after_ack = next_field

                if next_field:
                    follow_line = (
                        "After that, explain in 1–3 short sentences what the next field "
                        f"({describe_field(next_field)}) represents in the FIFO/DRAM/memory-controller context "
                        "and why it matters for hardware behavior.\n"
                        f"{make_prompt_line(self.current_kind, next_field)}"
                    )
                else:
                    follow_line = (
                        "Then note that the specification is complete and wait for the final summary; "
                        "do not output the JSON here."
                    )

                guidance = (
                    f"Current kind: {self.current_kind}\n"
                    f"Confirm field: {canon_with_friendly(ack_field)}\n"
                    "The user just answered this field.\n"
                    "Say exactly '✅ Set <field> to <value>.' before anything else.\n"
                    f"Immediately output UPDATE_JSON with that value on the next line (use path '{ack_field}').\n"
                    f"{follow_line}"
                )

            elif missing:
                default_line = make_prompt_line(self.current_kind, missing)
                guidance = (
                    f"Current kind: {self.current_kind}\n"
                    f"Ask for field: {canon_with_friendly(missing)}\n"
                    "Before you show the '🧩 Next field' line, first give 1–3 short sentences "
                    "explaining what this field represents in the FIFO/DRAM/memory-controller context "
                    "and why it matters for hardware behavior.\n"
                    f"{default_line}\n"
                    "Do not list multiple options.\n"
                    f"After the user responds, acknowledge with '✅ Set {missing} to <value>.' then "
                    "output UPDATE_JSON with path='{missing}'."
                )
                self.pending_ack_field = missing
                self.queued_field_after_ack = None
                self.ignore_update_for_field = None

            else:
                if not self.exported_once and self.working_spec is not None:
                    self.last_export_path = export_spec_auto(self.current_kind, self.working_spec)
                    self.exported_once = True
                location_line = (
                    f"Saved file: {self.last_export_path}"
                    if self.last_export_path
                    else "Saved file path is unknown."
                )
                guidance = (
                    f"All fields filled for {self.current_kind}.\n"
                    "Show the compact final JSON specification.\n"
                    f"Also mention: {location_line}"
                )

        self.messages.append({"role": "user", "content": f"{user}\n\n[GUIDANCE]\n{guidance}"})
        self.messages = trim_history(self.messages)

        assistant = stream_reply(self.messages) if use_stream else api_chat(self.messages)
        self.messages.append(assistant)

        txt = assistant["content"]

        # --- Parse UPDATE_JSON lines ---
        for line in txt.splitlines():
            if line.startswith("UPDATE_JSON="):
                try:
                    upd = json.loads(line.split("=", 1)[1])
                    raw_path = upd.get("path")
                    path = normalize_path(raw_path)
                    value = upd.get("value")

                    if path == "kind" and value in REGISTRY["kinds"]:
                        self.current_kind = value
                        self.working_spec = new_spec(value)
                        self.exported_once = False
                        self.last_export_path = None
                        self.pending_ack_field = None
                        self.queued_field_after_ack = None
                        self.ignore_update_for_field = None
                        self.auto_user_message = None

                    elif self.current_kind and self.working_spec is not None and path:
                        if isinstance(value, str) and value.strip().lower() == "default":
                            use = default_for(self.current_kind, path)
                            if use is not None:
                                value = use
                            else:
                                self.auto_user_message = make_prompt_line(self.current_kind, path)
                                continue

                        if self.ignore_update_for_field and path == self.ignore_update_for_field:
                            continue

                        if valid_path_for_kind(self.current_kind, path):
                            set_by_path(self.working_spec, path, value)
                            if self.pending_ack_field == path:
                                self.pending_ack_field = self.queued_field_after_ack
                                self.queued_field_after_ack = None

                            if self.current_kind:
                                missing_after_update = next_missing_field(self.current_kind, self.working_spec)
                                if missing_after_update is None:
                                    validation_errors = validate_spec(self.current_kind, self.working_spec)
                                    if validation_errors:
                                        first_path, reason = validation_errors[0]
                                        bad_val = get_by_path(self.working_spec, first_path)
                                        if valid_path_for_kind(self.current_kind, first_path):
                                            set_by_path(self.working_spec, first_path, None)
                                        self.pending_ack_field = None
                                        self.queued_field_after_ack = None
                                        self.exported_once = False
                                        self.last_export_path = None
                                        if self.auto_user_message is None:
                                            desc = describe_field(first_path)
                                            self.auto_user_message = (
                                                "The previous value the user provided was invalid.\n\n"
                                                f"[GUIDANCE]\n"
                                                f"Tell the user explicitly that the last value they provided for "
                                                f"{desc} was invalid. If possible, mention the bad value "
                                                f"({bad_val!r}) and explain why it is invalid:\n"
                                                f"{reason}\n"
                                                f"Then immediately re-ask for {desc} using the standard format:\n"
                                                f"{make_prompt_line(self.current_kind, first_path)}"
                                            )
                                    else:
                                        if not self.exported_once:
                                            self.last_export_path = export_spec_auto(self.current_kind, self.working_spec)
                                            self.exported_once = True
                                        if self.auto_user_message is None:
                                            self.auto_user_message = "[auto_finalize]"
                except Exception:
                    pass

        self.ignore_update_for_field = None
        txt = rewrite_user_visible_paths(txt)
        return txt

    def load_spec_file(self, file_path: str) -> List[str]:
        replies = []
        data = parse_spec_file(file_path)
        if not isinstance(data, dict):
            return [f"Could not parse file into an object: {file_path}"]

        kind = data.get("kind")
        if not kind:
            kind = infer_kind_from_text(json.dumps(data))
        if not kind or kind not in REGISTRY["kinds"]:
            return [f"Could not determine kind from file. Please add 'kind' or pick one: {self.available_kinds}"]

        self.current_kind = kind
        self.working_spec = new_spec(kind)
        self.exported_once = False
        self.last_export_path = None
        self.pending_ack_field = None
        self.queued_field_after_ack = None
        self.ignore_update_for_field = None
        self.auto_user_message = None

        applied_fields = []
        for path in ask_order(kind):
            v = get_by_path(data, path)
            if v in (None, "", []):
                continue

            if isinstance(v, str) and v.strip().lower() == "default":
                dv = default_for(kind, path)
                if dv is None:
                    continue
                v = dv

            set_by_path(self.working_spec, path, v)
            applied_fields.append(path)

        errs = validate_spec(kind, self.working_spec)
        cleared_fields = []
        for bad_path, _reason in errs:
            set_by_path(self.working_spec, bad_path, None)
            cleared_fields.append(bad_path)

        missing = next_missing_field(kind, self.working_spec)
        summary = f"Loaded file '{file_path}'. Kind={kind}. Applied {len(applied_fields)} fields."
        if applied_fields:
            summary += "\n• Applied: " + ", ".join(user_label_for_path(p) for p in applied_fields)
        if cleared_fields:
            summary += "\n• Cleared invalid: " + ", ".join(user_label_for_path(p) for p in cleared_fields)

        if missing:
            self.pending_ack_field = missing
            replies.append(summary)
            replies.append(make_prompt_line(kind, missing))
        else:
            self.last_export_path = export_spec_auto(kind, self.working_spec)
            self.exported_once = True
            replies.append(summary)
            replies.append(json.dumps(self.working_spec, indent=2))
            replies.append(f"Saved file: {self.last_export_path}")
        return replies

# --------- GUI welcome text ----------
WELCOME_MESSAGE = (
    "Hey, I'm your memory-controller spec assistant.\n\n"
    "Here's how this GUI works:\n"
    "• You'll be prompted to give needed specifications, feel free to ask for clarification or suggestions.\n"
    "• Press Enter or click Send to submit.\n"
    "• I'll reply here in the chat window.\n\n"
    "Start by selecting what type of memory controller you'd like to build"
)

# --------- PySide6 GUI ----------
class ChatWindow(QWidget):
    def __init__(self):
        super().__init__()

        self.setWindowTitle(f"TAMU Chat • Model: {MODEL}")
        self.resize(800, 600)

        self.engine = SpecEngine()

        main_layout = QVBoxLayout(self)

        header = QLabel(f"Model: {MODEL} • Endpoint: {BASE_URL}")
        header.setAlignment(Qt.AlignCenter)
        main_layout.addWidget(header)

        self.progress = QProgressBar()
        self.progress.setRange(0, 100)
        self.progress.setValue(0)
        self.progress.setFormat("0/0 fields (0%)")
        main_layout.addWidget(self.progress)

        self.chat_area = QTextEdit()
        self.chat_area.setReadOnly(True)
        main_layout.addWidget(self.chat_area)

        bottom_layout = QHBoxLayout()
        self.input = QLineEdit()
        self.input.setPlaceholderText("Type here and press Enter…")
        send_btn = QPushButton("Send")
        bottom_layout.addWidget(self.input)
        bottom_layout.addWidget(send_btn)
        main_layout.addLayout(bottom_layout)

        send_btn.clicked.connect(self.on_send_clicked)
        self.input.returnPressed.connect(self.on_send_clicked)

        self.add_message("Bot", WELCOME_MESSAGE)
        self.update_progress_bar()

        upload_btn = QPushButton("Upload spec file…")
        bottom_layout.addWidget(upload_btn)
        upload_btn.clicked.connect(self.on_upload_clicked)

    def on_upload_clicked(self):
        path, _ = QFileDialog.getOpenFileName(
            self,
            "Select spec file",
            os.getcwd(),
            "Spec Files (*.json *.txt *.yaml *.yml);;All Files (*)"
        )
        if not path:
            return
        self.add_message("You", f"[uploaded] {path}")
        try:
            replies = self.engine.load_spec_file(path)
        except Exception as e:
            replies = [f"Failed to load file: {e}"]
        for r in replies:
            if r:
                self.add_message("Bot", r)
        self.update_progress_bar()

    def update_progress_bar(self):
        filled, total = self.engine.progress()
        pct = int(100 * filled / total) if total > 0 else 0
        self.progress.setValue(pct)
        self.progress.setFormat(f"{filled}/{total} fields ({pct}%)")

    def add_message(self, who: str, text: str):
        safe = text.replace("\n", "<br>")
        self.chat_area.append(f"<b>{who}:</b> {safe}")

    def on_send_clicked(self):
        user_text = self.input.text().strip()
        if not user_text:
            return

        self.add_message("You", user_text)
        self.input.clear()

        try:
            replies = self.engine.handle_user(user_text)
        except Exception as e:
            replies = [f"Error talking to backend: {e}"]

        for r in replies:
            if r:
                self.add_message("Bot", r)

        self.update_progress_bar()

def gui_main():
    if not QT_AVAILABLE:
        print("PySide6 not installed; falling back to console mode.")
        console_main()
        return

    app = QApplication(sys.argv)
    window = ChatWindow()
    window.show()
    sys.exit(app.exec())

# ----------------------
# Console main loop
# ----------------------
def console_main():
    console.print(Panel.fit(
        f"Console Chat • Model: [bold]{MODEL}[/bold] • Endpoint: {BASE_URL} • Ctrl+C to exit",
        border_style="cyan"
    ))

    engine = SpecEngine()

    while True:
        try:
            user = session.prompt("\nYou> ").strip()
        except (EOFError, KeyboardInterrupt):
            console.print("\nBye!")
            break
        if not user:
            continue

        low = user.lower()
        if low in ("/exit", "/quit"):
            break
        if low == "/reset":
            engine.reset()
            console.print("[green]Session reset.[/green]")
            continue

        if low.startswith("/load "):
            path = user.split(" ", 1)[1].strip().strip('"')
            for r in engine.load_spec_file(path):
                console.print(r)
            continue

        reply = engine._one_turn(user, use_stream=True)
        console.print(f"[dim]Last reply length: {len(reply)} chars[/dim]")

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--console":
        console_main()
    else:
        gui_main()
