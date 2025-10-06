import os, sys, json, copy, re
from difflib import SequenceMatcher
from typing import List, Dict
from datetime import datetime
from rich.console import Console
from rich.panel import Panel
from prompt_toolkit import PromptSession
from prompt_toolkit.history import InMemoryHistory
import tiktoken
from openai import OpenAI

# --- Config from environment ---
OPENAI_BASE_URL="http://localhost:11434/v1"
OPENAI_MODEL="llama3.1:8b"
OPENAI_API_KEY="sk-local-anything"

#MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
#BASE_URL = os.getenv("OPENAI_BASE_URL")  # None = OpenAI cloud
#API_KEY = os.getenv("OPENAI_API_KEY")

MODEL=OPENAI_MODEL
BASE_URL=OPENAI_BASE_URL
API_KEY=OPENAI_API_KEY

if not API_KEY:
    print("Missing OPENAI_API_KEY. Put it in .env or your shell env."); sys.exit(1)

client = OpenAI(api_key=API_KEY, base_url=BASE_URL) if BASE_URL else OpenAI(api_key=API_KEY)
console = Console()
session = PromptSession(history=InMemoryHistory())

SYSTEM_MSG = (
    "You help a hardware engineer complete a JSON specification for on-chip memory controllers.\n"
    "Always follow any [GUIDANCE] block in the latest user turn.\n"
    "Rules:\n"
    "• Ask only for fields that appear in ask_order for the active kind.\n"
    "• If the kind is missing, request the user pick exactly one from the provided list.\n"
    "• When asking for a field, use the format: '<Field description>. Type a value or type 'default' to use <default value>.' If no default exists, say 'Type a value.' Do not list multiple options unless told to.\n"
    "• After the user answers, acknowledge with a sentence like 'Set <field> to <value>.' before emitting on a new line:\n"
    '  UPDATE_JSON={\"path\":\"<field.path>\",\"value\":<json_value>}\n'
    "  Use dot notation for the path (e.g. host_if.bus). Never invent fields or paths.\n"
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
    found=False
    for p in ask_order(kind):
        if p == current_path:
            found=True; continue
        if not found:
            continue
        v=get_by_path(spec, p)
        if v in (None, "", []):
            return p
    return None

def normalize_path(path: str | None) -> str | None:
    if path is None: return None
    p = path.strip()
    while p.startswith("/"):
        p = p[1:]
    p = p.replace("/", ".")
    return p

def valid_path_for_kind(kind: str, path: str) -> bool:
    if path == "kind": return True
    return path in ask_order(kind)


def describe_field(path: str) -> str:
    return path.replace("_", " ").replace(".", " ")


def _iter_spec_leaves(obj, prefix=""):
    if isinstance(obj, dict):
        for key, val in obj.items():
            new_prefix = f"{prefix}.{key}" if prefix else key
            yield from _iter_spec_leaves(val, new_prefix)
    else:
        yield prefix, obj


def validate_spec(kind: str, spec: dict) -> List[tuple[str, str]]:
    errors: List[tuple[str, str]] = []
    for path, value in _iter_spec_leaves(spec):
        if isinstance(value, str) and value.strip().lower() == "default":
            errors.append((path, "Replace 'default' with an explicit value."))
    return errors


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
    if not seq: return True
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


def sanitize_filename(s: str) -> str:
    return re.sub(r'[^A-Za-z0-9_.-]+', '_', s)

def export_spec_auto(kind: str, spec: dict) -> str:
    ts = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    name = sanitize_filename(spec.get("name") or kind)
    fname = f"{name}_{ts}.json"
    fpath = os.path.join(os.getcwd(), fname)
    with open(fpath, "w", encoding="utf-8") as f:
        json.dump(spec, f, indent=2)
    return fpath

# --- Tokenizer approx ---
enc = tiktoken.get_encoding("cl100k_base")
def token_estimate(messages: List[Dict]) -> int:
    text = "".join(m["role"] + ":" + m["content"] for m in messages)
    return len(enc.encode(text))
def trim_history(messages: List[Dict], budget: int = 6000) -> List[Dict]:
    base = [messages[0]]; rest = messages[1:]
    while rest and token_estimate(base+rest) > budget:
        rest.pop(0)
    return base+rest

def stream_reply(messages: List[Dict]) -> Dict:
    stream = client.chat.completions.create(
        model=MODEL, messages=messages,
        temperature=0.2, stream=True,
    )
    content=""
    for chunk in stream:
        delta = chunk.choices[0].delta.content or ""
        if delta:
            content += delta; console.print(delta,end="")
    console.print(); return {"role":"assistant","content":content}

def main():
    messages=[{"role":"system","content":SYSTEM_MSG}]
    console.print(Panel.fit(f"Console Chat • Model: [bold]{MODEL}[/bold] • Ctrl+C to exit",border_style="cyan"))
    current_kind=None; working_spec=None; exported_once=False
    last_export_path=None
    pending_ack_field=None
    queued_field_after_ack=None
    ignore_update_for_field=None
    auto_user_message=None
    available_kind_list=list(REGISTRY["kinds"].keys())
    available_kinds=", ".join(available_kind_list)

    while True:
        if auto_user_message is not None:
            user=auto_user_message
            auto_user_message=None
        else:
            try: user=session.prompt("\nYou> ").strip()
            except (EOFError,KeyboardInterrupt):
                console.print("\nBye!"); break
        if not user: continue

        low=user.lower()
        if low in ("/exit","/quit"): break
        if low=="/reset":
            messages=[{"role":"system","content":SYSTEM_MSG}]
            current_kind=None; working_spec=None; exported_once=False
            last_export_path=None
            pending_ack_field=None
            queued_field_after_ack=None
            ignore_update_for_field=None
            auto_user_message=None
            console.print("[green]Session reset.[/green]"); continue
        if low=="/spec":
            from rich import print_json
            print_json(data=working_spec if working_spec else {"info":"no kind"}); continue

        # Auto-kind detection if user mentions a kind name
        if current_kind is None:
            num_match=re.fullmatch(r"\d+", user)
            if num_match:
                idx=int(num_match.group())-1
                if 0 <= idx < len(available_kind_list):
                    chosen=available_kind_list[idx]
                    current_kind=chosen; working_spec=new_spec(chosen); exported_once=False
                    last_export_path=None
                    pending_ack_field=None
                    queued_field_after_ack=None
                    ignore_update_for_field=None
                    auto_user_message=None
                    console.print(f"[green]Kind set to {chosen}[/green]")
            if current_kind is None:
                detected = infer_kind_from_text(low)
                if detected:
                    current_kind = detected
                    working_spec = new_spec(detected)
                    exported_once = False
                    last_export_path=None
                    pending_ack_field=None
                    queued_field_after_ack=None
                    ignore_update_for_field=None
                    auto_user_message=None
                    console.print(f"[green]Kind set to {detected}[/green]")

        # Guidance for LLM
        if current_kind is None:
            guidance=f"Kind not chosen. Available: {available_kinds}"
        else:
            missing=next_missing_field(current_kind,working_spec)
            meta_question=False
            if auto_user_message is None and pending_ack_field and is_meta_question(user):
                meta_question=True
                ignore_update_for_field=pending_ack_field
            if meta_question and pending_ack_field:
                field=pending_ack_field
                dflt=default_for(current_kind,field)
                if dflt is None:
                    reask_line=(
                        f"After answering, ask again with: 'Please provide {describe_field(field)}. Type a value.'"
                    )
                else:
                    reask_line=(
                        f"After answering, ask again with: 'Please specify {describe_field(field)}. Type a value or type \"default\" to use {json.dumps(dflt)}.'"
                    )
                guidance=(
                    f"Current kind: {current_kind}\n"
                    f"The user asked a side question. Respond briefly to the question without changing any field values.\n"
                    "Do not emit UPDATE_JSON for this turn.\n"
                    f"{reask_line}"
                )
            elif pending_ack_field and missing == pending_ack_field:
                ack_field = pending_ack_field
                next_field = next_missing_after(current_kind,working_spec,ack_field)
                queued_field_after_ack = next_field
                if next_field:
                    next_default = default_for(current_kind,next_field)
                    if next_default is None:
                        follow_line=(
                            f"Then ask with: 'Please provide {describe_field(next_field)}. Type a value.'"
                        )
                    else:
                        follow_line=(
                            f"Then ask with: 'Please specify {describe_field(next_field)}. Type a value or type \"default\" to use {json.dumps(next_default)}.'"
                        )
                else:
                    follow_line="Then note that the specification is complete and wait for the final summary; do not output the JSON here."
                guidance=(
                    f"Current kind: {current_kind}\n"
                    f"Confirm field: {ack_field} ({describe_field(ack_field)})\n"
                    "The user just answered this field.\n"
                    "Say exactly 'Set <field> to <value>.' (present tense, no 'already') before anything else.\n"
                    "Immediately output UPDATE_JSON with that value on the next line.\n"
                    f"{follow_line}"
                )
            elif missing:
                dflt=default_for(current_kind,missing)
                if dflt is None:
                    default_line=(
                        f"Ask with one sentence of the form: 'Please provide {describe_field(missing)}. Type a value.'"
                    )
                else:
                    default_line=(
                        f"Ask with one sentence of the form: 'Please specify {describe_field(missing)}. Type a value or type \"default\" to use {json.dumps(dflt)}.'"
                    )
                guidance=(
                    f"Current kind: {current_kind}\n"
                    f"Ask for field: {missing}\n"
                    f"{default_line}\n"
                    "Do not list multiple options.\n"
                    f"After the user responds, acknowledge with 'Set {missing} to <value>.' then output UPDATE_JSON with path='{missing}'."
                )
                pending_ack_field = missing
                queued_field_after_ack = None
                ignore_update_for_field=None
            else:
                if not exported_once and working_spec is not None:
                    last_export_path=export_spec_auto(current_kind,working_spec)
                    exported_once=True
                    console.print(f"[green]Spec complete and saved to[/green] {last_export_path}")
                location_line=f"Saved file: {last_export_path}" if last_export_path else "Saved file path is unknown."
                guidance=(
                    f"All fields filled for {current_kind}.\n"
                    f"Show the compact final JSON specification.\n"
                    f"Also mention: {location_line}"
                )

        messages.append({"role":"user","content":f"{user}\n\n[GUIDANCE]\n{guidance}"})
        messages=trim_history(messages)
        console.print(f"[dim]~{token_estimate(messages)} prompt tokens[/dim]")
        assistant=stream_reply(messages); messages.append(assistant)
        console.print(f"[dim]Context ~{token_estimate(messages)} tokens[/dim]")

        # Parse UPDATE_JSON
        txt=assistant["content"]
        for line in txt.splitlines():
            if line.startswith("UPDATE_JSON="):
                try:
                    upd=json.loads(line.split("=",1)[1])
                    raw_path=upd.get("path"); path=normalize_path(raw_path); value=upd.get("value")
                    if path=="kind" and value in REGISTRY["kinds"]:
                        current_kind=value; working_spec=new_spec(value); exported_once=False
                        last_export_path=None
                        pending_ack_field=None
                        queued_field_after_ack=None
                        ignore_update_for_field=None
                        auto_user_message=None
                    elif current_kind and working_spec is not None and path:
                        if ignore_update_for_field and path == ignore_update_for_field:
                            console.print(f"[dim]Ignored update for {path} while addressing a side question.[/dim]")
                            continue
                        if valid_path_for_kind(current_kind,path):
                            set_by_path(working_spec,path,value)
                            if pending_ack_field == path:
                                pending_ack_field = queued_field_after_ack
                                queued_field_after_ack = None
                            validation_errors: List[tuple[str, str]] = []
                            if current_kind:
                                missing_after_update = next_missing_field(current_kind,working_spec)
                                if missing_after_update is None:
                                    validation_errors = validate_spec(current_kind,working_spec)
                                    if validation_errors:
                                        first_path, reason = validation_errors[0]
                                        console.print(f"[yellow]Invalid value for {first_path}: {reason}[/yellow]")
                                        if valid_path_for_kind(current_kind, first_path):
                                            set_by_path(working_spec, first_path, None)
                                        pending_ack_field = None
                                        queued_field_after_ack = None
                                        exported_once = False
                                        last_export_path = None
                                        if auto_user_message is None:
                                            auto_user_message=(
                                                f"The value provided for {describe_field(first_path)} was invalid. {reason} Please ask for {describe_field(first_path)} again using the standard format."
                                            )
                                    else:
                                        if not exported_once:
                                            last_export_path=export_spec_auto(current_kind,working_spec)
                                            exported_once=True
                                            console.print(f"[green]Spec complete and saved to[/green] {last_export_path}")
                                        if auto_user_message is None:
                                            auto_user_message="[auto_finalize]"
                            # progress
                            total=len(ask_order(current_kind)); filled=sum(1 for p in ask_order(current_kind) if get_by_path(working_spec,p) not in (None,"",[]))
                            console.print(f"[cyan]Progress: {filled}/{total} fields filled[/cyan]")
                        else:
                            console.print(f"[dim]Ignored unknown field: {raw_path} (normalized: {path})[/dim]")
                except Exception: pass

        ignore_update_for_field=None

if __name__=="__main__":
    main()
