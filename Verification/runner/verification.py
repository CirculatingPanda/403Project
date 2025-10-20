#!/usr/bin/env python3
"""
verification.py — LLM adapter + guarded-edit engine for testbench generation.

What it does
------------
- Scans a SystemVerilog template for @LLM_EDIT regions (single-line or block).
- Builds a minimal, deterministic spec context (no secrets, no files).
- Prompts an LLM to output ONLY the code replacements for those regions,
  in a strict JSON format (no prose).
- Applies the patches and returns the final testbench text.

Supported edit markers in your templates
----------------------------------------
1) Single-line placeholder:
   // @LLM_EDIT: TIMING_CYCLES
   (replaced by a few lines of code, inserted *below* the marker, or replacing a
   following block of commented '???' lines if present)

2) Named block:
   // @LLM_EDIT BEGIN TIMING_CYCLES
   ...anything in here will be replaced...
   // @LLM_EDIT END TIMING_CYCLES

Provider setup
--------------
- Choose provider via env var LLM_PROVIDER in {"openai","anthropic","echo"}.
- Set model via LLM_MODEL (e.g., "gpt-4.1" or "claude-3-5-sonnet").
- For OpenAI: set OPENAI_API_KEY.
- For Anthropic: set ANTHROPIC_API_KEY.

Usage
-----
from verification import GuardedEditEngine, OpenAIAdapter, AnthropicAdapter, EchoAdapter

engine = GuardedEditEngine(provider=OpenAIAdapter(model="gpt-4.1"))
final_text = engine.apply_llm_edits(template_text, spec_dict, extra_tasks=[...])
"""

from __future__ import annotations

import json
import math
import os
import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

# -----------------------------
# LLM Provider Adapters
# -----------------------------

class LLMAdapter:
    """Abstract base adapter."""
    def __init__(self, model: str):
        self.model = model

    def complete(self, system: str, user: str) -> str:
        raise NotImplementedError


class OpenAIAdapter(LLMAdapter):
    """Minimal OpenAI Chat Completions adapter (responses as plain text)."""
    def __init__(self, model: str):
        super().__init__(model)
        api_key = os.getenv("OPENAI_API_KEY", "")
        if not api_key:
            raise RuntimeError("OPENAI_API_KEY env var not set.")
        # Lazy import to avoid hard dependency if not used
        try:
            from openai import OpenAI  # type: ignore
        except Exception as e:
            raise RuntimeError("OpenAI python package not available. `pip install openai`") from e
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
    """Minimal Anthropic Messages API adapter."""
    def __init__(self, model: str):
        super().__init__(model)
        api_key = os.getenv("ANTHROPIC_API_KEY", "")
        if not api_key:
            raise RuntimeError("ANTHROPIC_API_KEY env var not set.")
        try:
            import anthropic  # type: ignore
        except Exception as e:
            raise RuntimeError("Anthropic python package not available. `pip install anthropic`") from e
        self._client = anthropic.Anthropic()

    def complete(self, system: str, user: str) -> str:
        msg = self._client.messages.create(
            model=self.model,
            system=system,
            max_tokens=2000,
            temperature=0.1,
            messages=[{"role": "user", "content": user}],
        )
        # Content is a list of blocks; concatenate text blocks
        parts = []
        for b in msg.content:
            if b.type == "text":
                parts.append(b.text)
        return "\n".join(parts)


class EchoAdapter(LLMAdapter):
    """Deterministic no-op adapter for CI/local testing without API keys."""
    def complete(self, system: str, user: str) -> str:
        # Return an empty JSON object for zero edits.
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

    Contract with the LLM
    ---------------------
    The LLM must return JSON like:
    {
      "edits": [
        {"name": "TIMING_CYCLES", "code": "int T_AA_CYC = 2;\\nint T_WC_CYC = 2;"},
        {"name": "TASK_DO_WRITE", "code": "task automatic do_write(...); ... endtask"}
      ]
    }
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
    ) -> str:
        """
        - Detect regions.
        - Build minimal prompt.
        - Call LLM.
        - Validate + apply patches.
        """
        regions = self._find_regions(template_text)
        if not regions:
            return template_text  # nothing to do

        # Prepare deterministic context (math in Python, not by LLM)
        ctx = self._build_context(spec, clk_ns=clk_ns)

        system_prompt = self._system_prompt()
        user_prompt = self._user_prompt(template_text, regions, ctx, extra_tasks or [])

        raw = self.provider.complete(system_prompt, user_prompt).strip()
        patches = self._parse_llm_json(raw)
        self._validate_patches(regions, patches)

        return self._apply_patches(template_text, regions, patches)

    # -------- Internals --------

    def _find_regions(self, text: str) -> List[EditRegion]:
        regions: List[EditRegion] = []

        # Block regions
        for m_begin in self.BLOCK_BEGIN_RE.finditer(text):
            name = m_begin.group(1)
            start = m_begin.end()  # replace AFTER BEGIN line
            # find corresponding END
            m_end = self.BLOCK_END_RE.search(text, pos=start)
            if not m_end or m_end.group(1) != name:
                raise ValueError(f"Unmatched @LLM_EDIT block for '{name}'.")
            end = m_end.start()  # replace up TO (but not including) END line
            original = text[start:end]
            regions.append(EditRegion(name=name, kind="block", start_idx=start, end_idx=end, original_text=original))

        # Single-line regions (insert directly after the marker, or replace nearby ??? lines)
        for m in self.SINGLE_LINE_RE.finditer(text):
            name = m.group(1)
            # By default, we replace the very next line if it contains "???" or is empty,
            # otherwise we insert after the marker.
            insert_pos = m.end()
            # Look ahead a small window to replace contiguous ??? lines
            look_ahead = text[insert_pos:insert_pos + 600]  # ample window
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

        # Deterministic cycle conversions (round up).
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
            "- Use integers for timing cycles already computed for you in 'timing_cycles'.\n"
            "- Do not introduce file I/O, DPI, or non-determinism.\n"
        )

    def _user_prompt(self, template_text: str, regions: List[EditRegion], ctx: Dict, extra_tasks: List[str]) -> str:
        # Extract small per-region stubs for better grounding
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
            "regions": region_snippets,
            "spec_context": ctx,
            "tasks": [
                "Fill timing constants/variables using 'timing_cycles' (already integer).",
                "Generate legal stimulus honoring protocol and timing cycles.",
                "If filling tasks (e.g., do_write/do_read), keep interfaces unchanged.",
                "Ensure endianness and byte-enable (be) handling are correct.",
                "Use $fatal on mismatches; do not print RESULT here unless the region is specifically for results.",
            ] + extra_tasks,
            "return_format": {
                "edits": [
                    {"name": "<REGION_NAME>", "code": "<SystemVerilog snippet>"}
                ]
            }
        }
        # Keep the user message compact and machine-friendly.
        return json.dumps(payload, indent=2)

    def _parse_llm_json(self, raw: str) -> Dict[str, str]:
        """
        Accept either raw JSON or JSON inside a code fence. Return mapping name->code.
        """
        txt = raw.strip()
        # Strip code fences if present
        fence = re.match(r"^```(?:json)?\s*(.*)```$", txt, flags=re.DOTALL)
        if fence:
            txt = fence.group(1).strip()

        try:
            obj = json.loads(txt)
        except json.JSONDecodeError as e:
            # Helpful error for debugging prompt/temperature
            raise ValueError(f"LLM did not return valid JSON. Raw:\n{raw}") from e

        if not isinstance(obj, dict) or "edits" not in obj or not isinstance(obj["edits"], list):
            raise ValueError("LLM JSON must have top-level key 'edits' as a list.")

        patches: Dict[str, str] = {}
        for item in obj["edits"]:
            if not isinstance(item, dict) or "name" not in item or "code" not in item:
                raise ValueError("Each edit must have 'name' and 'code'.")
            name = str(item["name"]).strip()
            code = str(item["code"])
            if not name:
                raise ValueError("Edit 'name' cannot be empty.")
            patches[name] = code
        return patches

    def _validate_patches(self, regions: List[EditRegion], patches: Dict[str, str]) -> None:
        region_names = {r.name for r in regions}
        # Ensure all patches correspond to existing regions
        for name in patches.keys():
            if name not in region_names:
                raise ValueError(f"LLM attempted to edit unknown region '{name}'.")
        # Optional: require all regions be filled (strict mode)
        missing = [r.name for r in regions if r.name not in patches]
        if missing:
            # Not fatal—allow partial filling. Uncomment to enforce strict:
            # raise ValueError(f"Missing edits for regions: {missing}")
            pass

        # Simple sanity checks: no forbidden tokens
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
        # Trim leading/trailing blank lines; keep internal formatting
        # Also strip code fences if a model returned them around a single edit.
        c = code.strip()
        m = re.match(r"^```(?:sv|systemverilog)?\s*(.*)```$", c, flags=re.DOTALL)
        if m:
            c = m.group(1).strip()
        return c

    @staticmethod
    def _provider_from_env() -> LLMAdapter:
        provider = os.getenv("LLM_PROVIDER", "echo").lower()
        model = os.getenv("LLM_MODEL", "gpt-4.1")
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
# CLI (optional)
# -----------------------------

def _load_json(path: str) -> Dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def _read(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def _write(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Apply LLM edits to @LLM_EDIT regions in a SV template.")
    ap.add_argument("--template", required=True, help="Path to SV template file with @LLM_EDIT markers.")
    ap.add_argument("--spec", required=True, help="Path to spec.json.")
    ap.add_argument("--out", required=True, help="Output path for patched testbench.")
    ap.add_argument("--clk-ns", type=float, default=None, help="Override clock period in ns.")
    ap.add_argument("--provider", choices=["openai", "anthropic", "echo"], default=os.getenv("LLM_PROVIDER", "echo"))
    ap.add_argument("--model", default=os.getenv("LLM_MODEL", "gpt-4.1"))
    args = ap.parse_args()

    # Choose provider
    if args.provider == "openai":
        provider = OpenAIAdapter(model=args.model)
    elif args.provider == "anthropic":
        provider = AnthropicAdapter(model=args.model)
    else:
        provider = EchoAdapter(model="echo")

    template_text = _read(args.template)
    spec = _load_json(args.spec)

    engine = GuardedEditEngine(provider=provider)
    patched = engine.apply_llm_edits(template_text, spec, extra_tasks=[], clk_ns=args.clk_ns)
    _write(args.out, patched)
    print(f"[verification.py] Wrote patched TB -> {args.out}")
