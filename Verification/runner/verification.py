#!/usr/bin/env python3
"""
verification.py — LLM adapter + guarded-edit engine for testbench generation.

- Scans a SystemVerilog template for @LLM_EDIT regions (single-line or block).
- Builds a minimal, deterministic spec context (no secrets, no files).
- Prompts an LLM to output ONLY the code replacements for those regions, in JSON.
- Applies the patches and returns the final testbench text.
"""

from __future__ import annotations

import json
import math
import os
import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple, Iterable

# Try to load .env if python-dotenv is available (handy for local dev)
try:
    from dotenv import load_dotenv, find_dotenv  # type: ignore
    load_dotenv(find_dotenv())
except Exception:
    pass

# -----------------------------
# LLM Provider Adapters
# -----------------------------

class LLMAdapter:
    """Abstract base adapter."""
    def __init__(self, model: str):
        self.model = model

    def complete(self, system: str, user: str) -> str:
        raise NotImplementedError


class TamusAdapter(LLMAdapter):
    """
    Adapter for TAMU AI (OpenAI-compatible proxy).
    Uses POST {ENDPOINT}/api/chat/completions with Bearer key.

    Env:
      - TAMUS_AI_CHAT_API_ENDPOINT (e.g., https://chat-api.tamu.ai)
      - TAMUS_AI_CHAT_API_KEY
    """
    def __init__(self, model: str):
        super().__init__(model)
        self._endpoint = os.getenv("TAMUS_AI_CHAT_API_ENDPOINT", "").rstrip("/")
        self._api_key = os.getenv("TAMUS_AI_CHAT_API_KEY", "")
        if not self._endpoint or not self._api_key:
            raise RuntimeError(
                "TAMU adapter requires TAMUS_AI_CHAT_API_ENDPOINT and TAMUS_AI_CHAT_API_KEY."
            )

        import requests  # lazy import
        self._requests = requests
        self._base = f"{self._endpoint}/api"  # TAMU uses /api (not /v1)
        self._url = f"{self._base}/chat/completions"
        self._session = requests.Session()
        self._session.headers.update({
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        })

    def complete(self, system: str, user: str) -> str:
        timeout_sec = int(os.getenv("TAMUS_TIMEOUT_SECS", "180"))
        max_retries = int(os.getenv("TAMUS_RETRIES", "1"))

        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": 0.1,
            "stream": False,
        }
        for attempt in range(max_retries):
            try:
                r = self._session.post(self._url, json=payload, timeout=timeout_sec)
                break
            except self._requests.exceptions.ReadTimeout:
                if attempt + 1 == max_retries:
                    raise
            print(f"[TAMU] Timeout, retrying ({attempt+1}/{max_retries})...")

        if r.status_code >= 400:
            try:
                detail = r.json()
            except Exception:
                detail = r.text
            raise RuntimeError(f"[TAMU] HTTP {r.status_code} from {self._url}\n{detail}")

        try:
            obj = r.json()
        except Exception:
            return r.text.strip()

        # OpenAI-style chat completions
        if isinstance(obj, dict) and "choices" in obj and obj["choices"]:
            ch0 = obj["choices"][0]
            if isinstance(ch0, dict):
                if "message" in ch0 and isinstance(ch0["message"], dict):
                    return ch0["message"].get("content", "") or ""
                if "text" in ch0:  # legacy compat
                    return str(ch0["text"])
        # Other common shapes
        if isinstance(obj, dict) and "output_text" in obj:
            return str(obj["output_text"])
        return json.dumps(obj, indent=2)


class OpenAIAdapter(LLMAdapter):
    """OpenAI Chat Completions adapter."""
    def __init__(self, model: str):
        super().__init__(model)
        api_key = os.getenv("OPENAI_API_KEY", "")
        if not api_key:
            raise RuntimeError("OPENAI_API_KEY env var not set.")
        try:
            from openai import OpenAI  # type: ignore
        except Exception as e:
            raise RuntimeError("OpenAI package missing. `pip install openai`") from e
        self._client = OpenAI()

    def complete(self, system: str, user: str) -> str:
        resp = self._client.chat.completions.create(
            model=self.model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            temperature=0.1,
        )
        return resp.choices[0].message.content or ""


class AnthropicAdapter(LLMAdapter):
    """Anthropic Messages API adapter."""
    def __init__(self, model: str):
        super().__init__(model)
        api_key = os.getenv("ANTHROPIC_API_KEY", "")
        if not api_key:
            raise RuntimeError("ANTHROPIC_API_KEY env var not set.")
        try:
            import anthropic  # type: ignore
        except Exception as e:
            raise RuntimeError("Anthropic package missing. `pip install anthropic`") from e
        self._client = anthropic.Anthropic()

    def complete(self, system: str, user: str) -> str:
        msg = self._client.messages.create(
            model=self.model,
            system=system,
            max_tokens=2000,
            temperature=0.1,
            messages=[{"role": "user", "content": user}],
        )
        parts: List[str] = []
        for b in msg.content:
            if getattr(b, "type", None) == "text":
                parts.append(getattr(b, "text", ""))
        return "\n".join(parts)


class EchoAdapter(LLMAdapter):
    """Deterministic no-op adapter for CI/local testing without API keys."""
    def __init__(self, model: str = "echo"):
        super().__init__(model)

    def complete(self, system: str, user: str) -> str:
        # Return an empty edits object (no changes)
        return json.dumps({"edits": []}, indent=2)


# -----------------------------
# Guarded Edit Engine
# -----------------------------

@dataclass
class EditRegion:
    name: str
    kind: str  # "single" or "block"
    start_idx: int  # char index in template where replacement begins
    end_idx: int    # char index where replacement ends (exclusive)
    original_text: str


class GuardedEditEngine:
    """
    Finds @LLM_EDIT regions in a template, asks an LLM for code to fill them,
    and applies the changes. Output is the patched template text.
    Contract with the LLM (JSON):
      { "edits": [ {"name": "<REGION>", "code": "<SV snippet>"} ] }
    """

    SINGLE_LINE_RE = re.compile(r"^[ \t]*//[ \t]*@LLM_EDIT:[ \t]*([A-Za-z0-9_]+)[ \t]*$", re.MULTILINE)
    BLOCK_BEGIN_RE = re.compile(r"^[ \t]*//[ \t]*@LLM_EDIT BEGIN[ \t]+([A-Za-z0-9_]+)[ \t]*$", re.MULTILINE)
    BLOCK_END_RE   = re.compile(r"^[ \t]*//[ \t]*@LLM_EDIT END[ \t]+([A-Za-z0-9_]+)[ \t]*$", re.MULTILINE)

    def __init__(self, provider: Optional[LLMAdapter] = None):
        if provider is None:
            provider = self._provider_from_env()
        self.provider = provider

    # -------- Public API --------

    def apply_llm_edits(
        self,
        template_text: str,
        spec: Dict,
        extra_tasks: Optional[List[str]] = None,
        clk_ns: Optional[float] = None,
        include_regions: Optional[Iterable[str]] = None,  # slice filter
    ) -> str:
        """
        - Detect regions (optionally filtered by include_regions).
        - Build minimal prompt.
        - Call LLM.
        - Validate + apply patches (lenient on unknown region names: dropped).
        """
        regions = self._find_regions(template_text)

        # Optional slice filter (stage-by-stage)
        if include_regions:
            want = {str(n).strip() for n in include_regions}
            regions = [r for r in regions if r.name in want]

        if not regions:
            return template_text  # nothing to do

        ctx = self._build_context(spec, clk_ns=clk_ns)
        system_prompt = self._system_prompt()
        user_prompt = self._user_prompt(template_text, regions, ctx, extra_tasks or [])

        raw = self.provider.complete(system_prompt, user_prompt).strip()
        patches = self._parse_llm_json(raw)
        self._validate_patches(regions, patches)   # drops unknown region names
        return self._apply_patches(template_text, regions, patches)

    # -------- Internals --------

    def _find_regions(self, text: str) -> List[EditRegion]:
        regions: List[EditRegion] = []

        # Block regions
        for m_begin in self.BLOCK_BEGIN_RE.finditer(text):
            name = m_begin.group(1)
            start = m_begin.end()  # replace AFTER BEGIN line
            m_end = self.BLOCK_END_RE.search(text, pos=start)
            if not m_end or m_end.group(1) != name:
                raise ValueError(f"Unmatched @LLM_EDIT block for '{name}'.")
            end = m_end.start()  # replace up TO (not incl.) END line
            original = text[start:end]
            regions.append(EditRegion(name=name, kind="block", start_idx=start, end_idx=end, original_text=original))

        # Single-line regions (insert after marker or replace nearby ???)
        for m in self.SINGLE_LINE_RE.finditer(text):
            name = m.group(1)
            insert_pos = m.end()
            look_ahead = text[insert_pos:insert_pos + 600]
            repl_span = re.match(r"(\s*(?://.*\?\?\?.*|/\*.*\?\?\?.*\*/|//.*|/\*.*\*/|\s)*)", look_ahead, re.DOTALL)
            if repl_span:
                end = insert_pos + repl_span.end()
            else:
                end = insert_pos
            regions.append(EditRegion(name=name, kind="single", start_idx=insert_pos, end_idx=end, original_text=text[insert_pos:end]))

        # Ensure unique names
        seen = set()
        for r in regions:
            if r.name in seen:
                raise ValueError(f"Duplicate @LLM_EDIT region name '{r.name}'. Names must be unique per file.")
            seen.add(r.name)

        return sorted(regions, key=lambda r: r.start_idx)

    def _build_context(self, spec: Dict, clk_ns: Optional[float]) -> Dict:
        ctx = {
            "controller_type": spec.get("controller_type"),
            "protocol": spec.get("protocol"),
            "data_width": spec.get("data_width"),
            "addr_width": spec.get("addr_width"),
            "endian": spec.get("endian"),
            "features": spec.get("features", {}),
            "address_map": spec.get("address_map", []),
            "sim": spec.get("sim", {}),
            "timing_ns": spec.get("timing", {}),
        }

        # Derive clock period if caller passes clk_ns or spec.sim.clock_mhz
        if clk_ns is not None:
            ctx["clk_ns"] = float(clk_ns)
        else:
            mhz = (spec.get("sim", {}) or {}).get("clock_mhz", 100)
            ctx["clk_ns"] = 1000.0 / float(mhz)

        # Deterministic cycle conversions (ceil)
        timing_cycles = {}
        for k, v in (ctx["timing_ns"] or {}).items():
            try:
                ns = float(v)
                timing_cycles[k.replace("_ns", "_cycles")] = int(math.ceil(ns / ctx["clk_ns"]))
            except Exception:
                continue
        ctx["timing_cycles"] = timing_cycles

        # Minimal stimulus info
        ctx["num_transactions"] = (ctx["sim"] or {}).get("num_transactions", 200)
        ctx["byte_enable_width"] = max(1, int((ctx["data_width"] or 8) // 8))
        return ctx

    def _system_prompt(self) -> str:
        return (
            "You are a senior verification engineer. You receive a SystemVerilog testbench "
            "template and a JSON spec context. Your ONLY job is to produce code for the marked "
            "@LLM_EDIT regions. Do not change module ports, imports, or any code outside those regions. "
            "Return STRICT JSON only, no prose. JSON schema:\n"
            '{ "edits": [ {"name": "<REGION_NAME>", "code": "<raw SystemVerilog to insert>"} ] }\n'
            "Notes:\n"
            "- Keep code Verilator/icarus-compatible (SystemVerilog-2012 subset).\n"
            "- Do not assign to expressions; LHS must be a variable or part-select.\n"
            "- Do not use $error; use $display/$fatal only.\n"
            "- When sampling read data, wait for rvalid if present, then sample on the next posedge to avoid races.\n"
            "- Hold addr stable from request assertion through read-data capture; deassert req/we between transactions.\n"
            "- Use integers for timing cycles already computed for you in 'timing_cycles'.\n"
            "- Do not introduce file I/O, DPI, or non-determinism.\n"
            "- Only produce edits for the provided region names. Do NOT include any other region names.\n"
            "- Declarations inside procedural blocks must appear before any executable statements (Icarus quirk).\n"
            "- Do not use 'final' blocks; use an 'initial' block with a wait-condition when needed (Icarus quirk).\n"
        )

    def _user_prompt(self, template_text: str, regions: List[EditRegion], ctx: Dict, extra_tasks: List[str]) -> str:
        # Extract small per-region stubs for grounding
        region_snippets = []
        for r in regions:
            snippet = template_text[max(0, r.start_idx - 300): min(len(template_text), r.end_idx + 300)]
            region_snippets.append({
                "name": r.name,
                "kind": r.kind,
                "context_snippet": snippet
            })

        payload = {
            "template_overview": "SystemVerilog testbench with guarded @LLM_EDIT regions.",
            "allowed_region_names": [r.name for r in regions],
            "rules": [
                "ONLY output edits for 'allowed_region_names'.",
                "Do not include edits for any other region names."
            ],
            "regions": region_snippets,
            "spec_context": ctx,
            "tasks": [
                "Fill timing constants/variables using 'timing_cycles' (already integer).",
                "Generate legal stimulus honoring protocol and timing cycles.",
                "If filling tasks (e.g., do_write/do_read), keep interfaces unchanged.",
                "Ensure endianness and byte-enable (be) handling are correct.",
                "Use $fatal on mismatches; do not print RESULT here unless the region is specifically for results.",
                "In procedural blocks, declare locals at the top before any statements.",
                "Avoid 'final'; use an 'initial' with a wait-condition.",
                "For reads, wait for rvalid (if present) and then sample rdata on next posedge; avoid same-cycle sampling.",
                "Keep addr stable during request and until read data capture; deassert req/we between transactions.",
                "After reset deassertion, wait 1-2 cycles before starting stimulus."
            ] + extra_tasks,
            "return_format": {
                "edits": [
                    {"name": "<REGION_NAME>", "code": "<SystemVerilog snippet>"}
                ]
            }
        }
        return json.dumps(payload, indent=2)

    def _parse_llm_json(self, raw: str) -> Dict[str, str]:
        """
        Accept either raw JSON or JSON inside a code fence.
        Return mapping name->code.
        If the response is not valid or not in the expected schema, fall back to
        an empty patch set (no edits) instead of raising.
        """
        txt = raw.strip()
        # Strip ```json ... ``` fences if present
        fence = re.match(r"^```(?:json)?\s*(.*)```$", txt, flags=re.DOTALL)
        if fence:
            txt = fence.group(1).strip()

        obj = None

        # First attempt: direct JSON
        try:
            obj = json.loads(txt)
        except json.JSONDecodeError:
            # Try to salvage a JSON object substring
            m = re.search(r"\{.*\}", txt, flags=re.DOTALL)
            if m:
                try:
                    obj = json.loads(m.group(0))
                except Exception:
                    obj = None

        if obj is None:
            print("[GuardedEditEngine] WARNING: LLM did not return valid JSON; treating as no edits.")
            return {}

        # If the model returned a bare list, wrap it
        if isinstance(obj, list):
            obj = {"edits": obj}

        if not isinstance(obj, dict):
            print("[GuardedEditEngine] WARNING: LLM JSON is not an object; treating as no edits.")
            return {}

        edits_list = obj.get("edits")
        if not isinstance(edits_list, list):
            print("[GuardedEditEngine] WARNING: LLM JSON missing 'edits' list; treating as no edits.")
            return {}

        patches: Dict[str, str] = {}
        for item in edits_list:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name", "")).strip()
            code = str(item.get("code", ""))
            if not name:
                continue
            patches[name] = code

        return patches

    def _validate_patches(self, regions: List[EditRegion], patches: Dict[str, str]) -> None:
        """
        Lenient validator: drop unknown region names (stage isolation),
        still enforce safety rules.
        """
        region_names = {r.name for r in regions}

        # Drop unknown patches instead of raising
        unknown = [name for name in list(patches.keys()) if name not in region_names]
        for name in unknown:
            patches.pop(name, None)

        # Safety scans (basic)
        forbidden = ["$fopen", "$fread", "$system", "import \"DPI-C\"", "`include"]
        for name, code in patches.items():
            for token in forbidden:
                if token in code:
                    raise ValueError(f"Edit '{name}' contains forbidden token '{token}'.")

    def _apply_patches(self, text: str, regions: List[EditRegion], patches: Dict[str, str]) -> str:
        # Apply from end to start to keep indices valid
        regions_sorted = sorted(regions, key=lambda r: r.start_idx, reverse=True)
        out = text
        for r in regions_sorted:
            code = patches.get(r.name, "")
            replacement = self._normalize_code(code)
            out = out[:r.start_idx] + "\n" + replacement.rstrip() + "\n" + out[r.end_idx:]
        return out

    @staticmethod
    def _normalize_code(code: str) -> str:
        # Trim leading/trailing blank lines; strip code fences if present
        c = code.strip()
        m = re.match(r"^```(?:sv|systemverilog)?\s*(.*)```$", c, flags=re.DOTALL)
        if m:
            c = m.group(1).strip()
        return c

    @staticmethod
    def _provider_from_env() -> LLMAdapter:
        provider = os.getenv("LLM_PROVIDER", "echo").lower()
        model = os.getenv("LLM_MODEL", "protected.gpt-5")
        if provider == "tamu":
            return TamusAdapter(model=model)
        if provider == "openai":
            return OpenAIAdapter(model=model)
        if provider == "anthropic":
            return AnthropicAdapter(model=model)
        return EchoAdapter(model="echo")


# -----------------------------
# Convenience function
# -----------------------------

def apply_edits_with_provider(
    template_text: str,
    spec: Dict,
    extra_tasks: Optional[List[str]] = None,
    clk_ns: Optional[float] = None,
    provider: Optional[LLMAdapter] = None,
) -> str:
    """
    One-liner for callers (e.g., generate_tb.py).
    """
    engine = GuardedEditEngine(provider=provider)
    return engine.apply_llm_edits(template_text, spec, extra_tasks=extra_tasks, clk_ns=clk_ns)


# -----------------------------
# Optional CLI (useful for quick tests)
# -----------------------------

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Apply LLM edits to @LLM_EDIT regions in a SV template.")
    ap.add_argument("--template", required=True, help="Path to SV template file with @LLM_EDIT markers.")
    ap.add_argument("--spec", required=True, help="Path to spec.json.")
    ap.add_argument("--out", required=True, help="Output path for patched testbench.")
    ap.add_argument("--clk-ns", type=float, default=None, help="Override clock period in ns.")
    ap.add_argument("--provider",
                    choices=["tamu", "openai", "anthropic", "echo"],
                    default=os.getenv("LLM_PROVIDER", "tamu"))
    ap.add_argument("--model", default=os.getenv("LLM_MODEL", "protected.gpt-5"))
    args = ap.parse_args()

    # Choose provider
    if args.provider == "tamu":
        provider = TamusAdapter(model=args.model)
    elif args.provider == "openai":
        provider = OpenAIAdapter(model=args.model)
    elif args.provider == "anthropic":
        provider = AnthropicAdapter(model=args.model)
    else:
        provider = EchoAdapter(model="echo")

    with open(args.template, "r", encoding="utf-8") as f:
        template_text = f.read()
    with open(args.spec, "r", encoding="utf-8") as f:
        spec = json.load(f)

    engine = GuardedEditEngine(provider=provider)
    patched = engine.apply_llm_edits(template_text, spec, extra_tasks=[], clk_ns=args.clk_ns)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(patched)
    print(f"[verification.py] Wrote patched TB -> {args.out}")
