import os, sys
from typing import List, Dict
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
    "You are a helpful assistant for gathering chip-design requirements. "
    "Ask at most two concise questions per turn. Offer sensible defaults. "
    "When all fields are known, summarize them as a compact JSON object."
)

# Tokenizer that approximates GPT-4o tokenization
enc = tiktoken.get_encoding("cl100k_base")

def token_estimate(messages: List[Dict]) -> int:
    text = "".join(m["role"] + ":" + m["content"] for m in messages)
    return len(enc.encode(text))

def trim_history(messages: List[Dict], budget: int = 6000) -> List[Dict]:
    base = [messages[0]]  # keep system
    rest = messages[1:]
    while rest and token_estimate(base + rest) > budget:
        rest.pop(0)  # drop oldest
    return base + rest

def stream_reply(messages: List[Dict]) -> Dict:
    stream = client.chat.completions.create(
        model=MODEL,
        messages=messages,
        temperature=0.2,
        stream=True,
    )
    content = ""
    for chunk in stream:
        delta = chunk.choices[0].delta.content or ""
        if delta:
            content += delta
            console.print(delta, end="")
    console.print()
    return {"role": "assistant", "content": content}

def main():
    messages = [{"role": "system", "content": SYSTEM_MSG}]
    console.print(Panel.fit(f"Console Chat • Model: [bold]{MODEL}[/bold] • Ctrl+C to exit", border_style="cyan"))

    while True:
        try:
            user = session.prompt("\nYou> ").strip()
        except (EOFError, KeyboardInterrupt):
            console.print("\nBye!"); break
        if not user:
            continue

        # simple commands
        low = user.lower()
        if low in ("/exit", "/quit"): break
        if low == "/help":
            console.print("Commands: /help /reset /tokens /history /exit"); continue
        if low == "/reset":
            messages = [{"role": "system", "content": SYSTEM_MSG}]
            console.print("[green]Session reset.[/green]"); continue
        if low == "/tokens":
            console.print(f"~{token_estimate(messages)} tokens in context."); continue
        if low == "/history":
            for m in messages: console.print(f"[{m['role']}] {m['content'][:200]}")
            continue

        messages.append({"role": "user", "content": user})
        messages = trim_history(messages)
        console.print(f"[dim]~{token_estimate(messages)} prompt tokens[/dim]")
        assistant = stream_reply(messages)
        messages.append(assistant)
        console.print(f"[dim]Context ~{token_estimate(messages)} tokens[/dim]")

if __name__ == "__main__":
    main()
