import os, sys, json, copy, re
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
    "You are a requirements-gathering assistant for memory controllers.\n"
    "Rules:\n"
    "• ONLY ask for fields from ask_order for the chosen kind.\n"
    "• DO NOT invent new fields.\n"
    "• When proposing a default, NEVER say 'press Enter'. Instead say:\n"
    "  'Type a value or type the word default'.\n"
    "Flow:\n"
    "1) If kind is not set, ask user to choose ONE from the list.\n"
    "2) Once kind is set, ask ONLY for the next missing field.\n"
    "   Offer ONE sensible default.\n"
    "3) When user answers, reply briefly, and ALSO output on a new line:\n"
    '   UPDATE_JSON={\"path\":\"<field.path>\",\"value\":<json_value>}\n'
    "   Path MUST be dot notation (e.g. host_if.bus). Do NOT use slashes.\n"
    "4) When all fields are filled, present the final compact JSON spec."
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

def sanitize_filename(s: str) -> str:
    return re.sub(r'[^A-Za-z0-9_.-]+', '_', s)

def export_spec_auto(kind: str, spec: dict) -> str:
    os.makedirs("specs", exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    fname = f"{sanitize_filename(kind)}_{ts}.json"
    fpath = os.path.join("specs", fname)
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
    available_kinds=", ".join(REGISTRY["kinds"].keys())

    while True:
        try: user=session.prompt("\nYou> ").strip()
        except (EOFError,KeyboardInterrupt):
            console.print("\nBye!"); break
        if not user: continue

        low=user.lower()
        if low in ("/exit","/quit"): break
        if low=="/reset":
            messages=[{"role":"system","content":SYSTEM_MSG}]
            current_kind=None; working_spec=None; exported_once=False
            console.print("[green]Session reset.[/green]"); continue
        if low=="/spec":
            from rich import print_json
            print_json(data=working_spec if working_spec else {"info":"no kind"}); continue

        # Auto-kind detection if user mentions a kind name
        if current_kind is None:
            for k in REGISTRY["kinds"].keys():
                if k in low.replace(" ","_"):
                    current_kind=k; working_spec=new_spec(k); exported_once=False
                    console.print(f"[green]Kind set to {k}[/green]")

        # Guidance for LLM
        if current_kind is None:
            guidance=f"Kind not chosen. Available: {available_kinds}"
        else:
            missing=next_missing_field(current_kind,working_spec)
            if missing:
                dflt=default_for(current_kind,missing)
                guidance=(
                    f"Current kind: {current_kind}\n"
                    f"Here is the next field we need to complete: {missing}\n"
                    f"Suggested default: {json.dumps(dflt)}\n"
                    "Tell user to type a value or 'default'.\n"
                    f"Output UPDATE_JSON with path='{missing}' only."
                )
            else:
                guidance=f"All fields filled for {current_kind}. Show final spec."

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
                    elif current_kind and working_spec is not None and path:
                        if valid_path_for_kind(current_kind,path):
                            set_by_path(working_spec,path,value)
                            # progress
                            total=len(ask_order(current_kind)); filled=sum(1 for p in ask_order(current_kind) if get_by_path(working_spec,p) not in (None,"",[]))
                            console.print(f"[cyan]Progress: {filled}/{total} fields filled[/cyan]")
                        else:
                            console.print(f"[dim]Ignored unknown field: {raw_path} (normalized: {path})[/dim]")
                except Exception: pass

        # Auto-export when complete
        if current_kind and working_spec and next_missing_field(current_kind,working_spec) is None and not exported_once:
            path=export_spec_auto(current_kind,working_spec); exported_once=True
            console.print(f"[green]Spec complete and saved to[/green] {path}")

if __name__=="__main__":
    main()
