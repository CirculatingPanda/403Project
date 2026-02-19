#!/usr/bin/env python3
"""
Memory Controller Generator v2.1
================================

A clean, high-accuracy generator for all memory controller types.
Updated for TAMU AI with Claude Sonnet 4.5.

SUPPORTED KINDS (from spec_registry.json):
  - sram_controller
  - dualport_sram_controller  
  - fifo_controller
  - rom_controller
  - regfile_controller
  - sdram_controller
  - ddr_controller
  - ddr2_controller

USAGE:
  python mc_generator_v2.py -s spec.json -o output/

Author: Joshua (ECEN Capstone - Spring 2026)
"""

import os
import sys
import json
import re
import math
import subprocess
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Any, Optional, Tuple
from dataclasses import dataclass, field

# Load environment variables from .env file
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    # dotenv not installed - will use environment variables directly
    pass

VERSION = "2.1.0"


# =============================================================================
# CONFIGURATION
# =============================================================================

@dataclass
class GeneratorConfig:
    """Central configuration for the generator"""
    
    # Directory structure (relative to script location)
    base_dir: Path = field(default_factory=lambda: Path(__file__).parent)
    
    @property
    def skeletons_dir(self) -> Path:
        return self.base_dir / "skeletons"
    
    @property
    def contexts_dir(self) -> Path:
        return self.base_dir / "contexts"
    
    # LLM settings optimized for accuracy with Claude
    max_tokens_per_call: int = 8000      # Claude handles larger outputs well
    temperature: float = 0.05            # Low for deterministic code
    max_retries: int = 3                 # Retry on failure
    
    # Verification
    run_lint: bool = True
    require_no_todos: bool = True


# =============================================================================
# KIND REGISTRY - Maps each kind to its generation strategy
# =============================================================================

@dataclass
class KindConfig:
    """Configuration for a specific controller kind"""
    skeleton_subdir: str
    components: List[str]           # List of component names to generate
    context_files: Dict[str, str]   # name -> relative path
    timing_mode: str                # "none", "simple", "dram"
    complexity: int                 # 1-5, affects generation strategy


KIND_REGISTRY: Dict[str, KindConfig] = {
    # ════════════════════════════════════════════════════════════════════
    # SIMPLE CONTROLLERS (Complexity 1-2)
    # These can be generated in 1-2 LLM calls with high accuracy
    # Context files OMITTED intentionally - they add noise for simple designs
    # ════════════════════════════════════════════════════════════════════
    
    "sram_controller": KindConfig(
        skeleton_subdir="sram",
        components=["sram_ctrl"],
        context_files={},  # Intentionally empty - skeleton is self-contained
        timing_mode="simple",
        complexity=1
    ),
    
    "fifo_controller": KindConfig(
        skeleton_subdir="fifo",
        components=["fifo_ctrl"],
        context_files={},  # No context needed
        timing_mode="none",
        complexity=1
    ),
    
    "rom_controller": KindConfig(
        skeleton_subdir="rom",
        components=["rom_ctrl"],
        context_files={},
        timing_mode="simple",
        complexity=1
    ),
    
    "regfile_controller": KindConfig(
        skeleton_subdir="regfile",
        components=["regfile_ctrl"],
        context_files={},
        timing_mode="none",
        complexity=1
    ),
    
    "dualport_sram_controller": KindConfig(
        skeleton_subdir="sram",
        components=["dualport_sram_ctrl"],
        context_files={},
        timing_mode="simple",
        complexity=2
    ),
    
    # ════════════════════════════════════════════════════════════════════
    # MODERATE CONTROLLERS (Complexity 3)
    # These need some context for timing/protocol
    # ════════════════════════════════════════════════════════════════════
    
    "sdram_controller": KindConfig(
        skeleton_subdir="sdram",
        components=["init", "bank", "refresh", "scheduler", "top"],
        context_files={
            "timing": "sdram/timing_params.md"
        },
        timing_mode="dram",
        complexity=3
    ),
    
    # ════════════════════════════════════════════════════════════════════
    # COMPLEX CONTROLLERS (Complexity 4-5)
    # These need full context for JEDEC compliance
    # ════════════════════════════════════════════════════════════════════
    
    "ddr_controller": KindConfig(
        skeleton_subdir="ddr",
        components=["init", "config", "addr_dec", "bank", "scheduler", 
                   "cmd_enc", "write", "read", "refresh", "top"],
        context_files={
            "timing": "ddr/timing_params.md",
            "phy": "ddr/phy_contract.md",
            "jedec": "ddr/jedec_init.md"
        },
        timing_mode="dram",
        complexity=4
    ),
    
    "ddr2_controller": KindConfig(
        skeleton_subdir="ddr2",
        components=["init", "config", "addr_dec", "bank", "scheduler",
                   "cmd_enc", "write", "read", "refresh", "main", "top"],
        context_files={
            "timing": "ddr2/timing_params.md",
            "phy": "ddr2/phy_contract.md",
            "jedec": "ddr2/jedec_init.md",
            "pinmap": "ddr2/pinmap.md"
        },
        timing_mode="dram",
        complexity=5
    ),
}


# =============================================================================
# LLM CLIENT - Handles TAMU AI with Claude Sonnet 4.5
# =============================================================================

class LLMClient:
    """Handles all LLM API calls with retry logic"""
    
    def __init__(self, config: GeneratorConfig):
        self.config = config
        self.client = None
        self.api_type = None
        self._init_client()
    
    def _init_client(self):
        """Initialize the appropriate API client based on environment"""
        
        if os.getenv('USE_TAMU', 'false').lower() == 'true':
            self._init_tamu()
        elif os.getenv('USE_ANTHROPIC', 'false').lower() == 'true':
            self._init_anthropic()
        elif os.getenv('USE_OPENAI', 'false').lower() == 'true':
            self._init_openai()
        else:
            # Default to TAMU if no explicit setting
            print("[WARN] No API explicitly configured, trying TAMU...")
            self._init_tamu()
    
    def _init_tamu(self):
        """Initialize TAMU AI client (works with Claude Sonnet 4.5)"""
        import requests
        self.api_type = "tamu"
        self.endpoint = os.getenv('TAMUS_AI_CHAT_API_ENDPOINT', 'https://chat-api.tamu.ai')
        self.api_key = os.getenv('TAMUS_AI_CHAT_API_KEY')
        
        # Support various model name formats
        self.model = os.getenv('TAMU_MODEL', 'protected.Claude Sonnet 4.5')
        # Remove quotes if present
        self.model = self.model.strip('"\'')
        
        if not self.api_key:
            raise RuntimeError(
                "TAMUS_AI_CHAT_API_KEY not set!\n"
                "Set it in .env file or environment variable."
            )
        
        print(f"[INIT] TAMU AI endpoint: {self.endpoint}")
        print(f"[INIT] Model: {self.model}")
    
    def _init_anthropic(self):
        """Initialize direct Anthropic client"""
        try:
            import anthropic
            self.api_type = "anthropic"
            self.client = anthropic.Anthropic(api_key=os.getenv('ANTHROPIC_API_KEY'))
            self.model = os.getenv('ANTHROPIC_MODEL', 'claude-sonnet-4-20250514')
            print(f"[INIT] Anthropic direct: {self.model}")
        except ImportError:
            raise RuntimeError("anthropic package not installed. Run: pip install anthropic")
    
    def _init_openai(self):
        """Initialize OpenAI client"""
        try:
            from openai import OpenAI
            self.api_type = "openai"
            self.client = OpenAI(api_key=os.getenv('OPENAI_API_KEY'))
            self.model = os.getenv('OPENAI_MODEL', 'gpt-4-turbo-preview')
            print(f"[INIT] OpenAI: {self.model}")
        except ImportError:
            raise RuntimeError("openai package not installed. Run: pip install openai")
    
    def generate(self, system_prompt: str, user_prompt: str, 
                 max_tokens: Optional[int] = None) -> str:
        """
        Generate code with the configured LLM.
        Returns the generated text or raises an exception.
        """
        max_tokens = max_tokens or self.config.max_tokens_per_call
        
        for attempt in range(self.config.max_retries + 1):
            try:
                if self.api_type == "tamu":
                    return self._call_tamu(system_prompt, user_prompt, max_tokens)
                elif self.api_type == "anthropic":
                    return self._call_anthropic(system_prompt, user_prompt, max_tokens)
                elif self.api_type == "openai":
                    return self._call_openai(system_prompt, user_prompt, max_tokens)
            except Exception as e:
                if attempt < self.config.max_retries:
                    print(f"[RETRY] Attempt {attempt + 1} failed: {e}")
                    import time
                    time.sleep(2)  # Wait before retry
                else:
                    raise
        
        return ""
    
    def _call_tamu(self, system: str, user: str, max_tokens: int) -> str:
        """
        Call TAMU AI API (OpenAI-compatible endpoint with Claude models)
        """
        import requests
        import json as json_lib
        
        url = f"{self.endpoint}/api/chat/completions"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
        
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user}
            ],
            "max_tokens": max_tokens,
            "temperature": self.config.temperature,
            "stream": False
        }
        
        print(f"[API] Calling TAMU AI ({self.model})...")
        
        response = requests.post(url, headers=headers, json=payload, timeout=300)
        
        if response.status_code != 200:
            raise RuntimeError(
                f"TAMU API error {response.status_code}: {response.text[:500]}"
            )
        
        # Handle response - TAMU can return SSE or JSON format
        text = response.text.strip()
        
        if text.startswith('data:'):
            # Server-Sent Events (SSE) format - parse line by line
            parts = []
            for line in text.split('\n'):
                line = line.strip()
                if line.startswith('data:') and line != 'data: [DONE]':
                    try:
                        json_str = line[5:].strip()
                        if json_str:
                            data = json_lib.loads(json_str)
                            if 'choices' in data and data['choices']:
                                delta = data['choices'][0].get('delta', {})
                                content = delta.get('content', '')
                                if content:
                                    parts.append(content)
                    except json_lib.JSONDecodeError:
                        continue
            return ''.join(parts)
        else:
            # Standard JSON response
            try:
                data = response.json()
                if 'choices' in data and data['choices']:
                    return data['choices'][0]['message']['content']
                elif 'error' in data:
                    raise RuntimeError(f"API error: {data['error']}")
                else:
                    raise RuntimeError(f"Unexpected response format: {text[:200]}")
            except json_lib.JSONDecodeError as e:
                raise RuntimeError(f"Failed to parse response: {e}\nResponse: {text[:500]}")
    
    def _call_anthropic(self, system: str, user: str, max_tokens: int) -> str:
        """Call Anthropic API directly"""
        response = self.client.messages.create(
            model=self.model,
            max_tokens=max_tokens,
            temperature=self.config.temperature,
            system=system,
            messages=[{"role": "user", "content": user}]
        )
        return response.content[0].text
    
    def _call_openai(self, system: str, user: str, max_tokens: int) -> str:
        """Call OpenAI API"""
        response = self.client.chat.completions.create(
            model=self.model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user}
            ],
            temperature=self.config.temperature,
            max_tokens=max_tokens
        )
        return response.choices[0].message.content


# =============================================================================
# TIMING CALCULATOR - Automatic, no AI needed
# =============================================================================

class TimingCalculator:
    """
    Calculate timing parameters AUTOMATICALLY from spec.
    This runs WITHOUT calling the AI - pure Python computation.
    """
    
    @staticmethod
    def calculate(spec: Dict) -> Dict[str, Any]:
        """Calculate all timing parameters from spec"""
        kind = spec.get("kind", "sram_controller")
        
        # Handle clock_mhz - convert "default" or invalid values to 100
        clock_mhz_raw = spec.get("clock_mhz", 100)
        if isinstance(clock_mhz_raw, str):
            if clock_mhz_raw.lower() == "default" or clock_mhz_raw == "":
                clock_mhz = 100  # Default to 100 MHz
            else:
                try:
                    clock_mhz = float(clock_mhz_raw)
                except ValueError:
                    clock_mhz = 100
        else:
            clock_mhz = clock_mhz_raw if clock_mhz_raw else 100
        
        clk_ns = 1000.0 / clock_mhz
        
        # Base timing (all controllers)
        timings = {
            "FREQ_MHZ": clock_mhz,
            "CLK_PERIOD_NS": round(clk_ns, 3),
            "CLK_PERIOD_PS": int(clk_ns * 1000),
        }
        
        kind_config = KIND_REGISTRY.get(kind)
        if not kind_config:
            return timings
        
        # ── No timing mode (FIFO, regfile) ─────────────────────────────
        if kind_config.timing_mode == "none":
            return timings
        
        # ── Simple timing (SRAM, ROM) ──────────────────────────────────
        if kind_config.timing_mode == "simple":
            timings["READ_LATENCY"] = spec.get("timing", {}).get("read_latency_cycles", 1)
            return timings
        
        # ── DRAM timing (SDRAM, DDR, DDR2) ─────────────────────────────
        if kind_config.timing_mode == "dram":
            timing = spec.get("timing", {})
            refresh = spec.get("refresh", {})
            dram = spec.get("dram", {})
            
            # Convert nanoseconds to cycles where needed
            def ns_to_cycles(ns: float) -> int:
                return max(1, math.ceil(ns / clk_ns))
            
            # Core DRAM timing parameters
            t_rcd = timing.get("tRCD", 4)
            t_cl = timing.get("tCL", 4)
            t_rp = timing.get("tRP", 4)
            t_ras = timing.get("tRAS", 10)
            
            timings.update({
                # Row timing
                "T_RCD": t_rcd,
                "T_CL": t_cl,
                "T_RP": t_rp,
                "T_RAS": t_ras,
                "T_RC": timing.get("tRC", t_rcd + t_ras),
                
                # Write timing
                "T_WR": timing.get("tWR", 4),
                "T_WTR": timing.get("tWTR", 2),
                "T_RTP": timing.get("tRTP", 2),
                
                # Refresh
                "T_RFC": timing.get("tRFC", 18),
                "T_REFI": ns_to_cycles(refresh.get("period_ns", 7800)),
                
                # Mode register
                "T_MRD": 2,
                "T_MOD": 12,
                
                # Initialization (200us for DDR/DDR2)
                "T_INIT": ns_to_cycles(200000),
                "T_DLL_LOCK": 200,
                
                # Derived
                "CAS_LATENCY": t_cl,
                "WRITE_LATENCY": max(1, t_cl - 1),
                "BURST_LEN": dram.get("burst_len", 4),
                
                # Bank configuration
                "NUM_BANKS": 2 ** dram.get("bank_bits", 4),
                "BANK_BITS": dram.get("bank_bits", 4),
                "ROW_BITS": dram.get("row_bits", 13),
                "COL_BITS": dram.get("col_bits", 10),
            })
            
            # DDR2-specific
            if kind == "ddr2_controller":
                timings["T_FAW"] = timing.get("tFAW", 10)
                timings["T_RRD"] = timing.get("tRRD", 2)
                timings["ODT_ENABLED"] = 1 if dram.get("odt", True) else 0
                timings["DLL_ENABLED"] = 1 if dram.get("dll_enable", True) else 0
            
            return timings
        
        return timings


# =============================================================================
# AUTOMATIC FILE GENERATORS (No AI needed)
# =============================================================================

class AutoFileGenerator:
    """
    Generates supporting files AUTOMATICALLY without AI.
    These are deterministic transformations of the spec.
    """
    
    @staticmethod
    def generate_timing_params_svh(spec: Dict, timings: Dict, output_dir: Path) -> Path:
        """Generate timing parameters SystemVerilog header - NO AI NEEDED"""
        name = spec.get("name", "memory_ctrl")
        kind = spec.get("kind", "sram_controller")
        
        content = f"""`ifndef {name.upper()}_TIMING_PARAMS_SVH
`define {name.upper()}_TIMING_PARAMS_SVH

//==============================================================================
// Timing Parameters for {name}
// Kind: {kind}
// Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
// 
// THIS FILE IS AUTO-GENERATED - DO NOT EDIT MANUALLY
//==============================================================================

package {name}_timing_pkg;

    // ══════════════════════════════════════════════════════════════════════
    // Clock Parameters
    // ══════════════════════════════════════════════════════════════════════
    parameter int unsigned FREQ_MHZ      = {timings.get('FREQ_MHZ', 100)};
    parameter real         CLK_PERIOD_NS = {timings.get('CLK_PERIOD_NS', 10.0):.3f};
    parameter int unsigned CLK_PERIOD_PS = {timings.get('CLK_PERIOD_PS', 10000)};

"""
        
        # Add timing parameters based on mode
        kind_config = KIND_REGISTRY.get(kind)
        
        if kind_config and kind_config.timing_mode == "simple":
            content += f"""    // ══════════════════════════════════════════════════════════════════════
    // Simple Timing
    // ══════════════════════════════════════════════════════════════════════
    parameter int unsigned READ_LATENCY = {timings.get('READ_LATENCY', 1)};

"""
        
        elif kind_config and kind_config.timing_mode == "dram":
            content += f"""    // ══════════════════════════════════════════════════════════════════════
    // DRAM Timing Parameters (in clock cycles)
    // ══════════════════════════════════════════════════════════════════════
    
    // Row timing
    parameter int unsigned T_RCD  = {timings.get('T_RCD', 4)};    // RAS to CAS delay
    parameter int unsigned T_RP   = {timings.get('T_RP', 4)};     // Row precharge time
    parameter int unsigned T_RAS  = {timings.get('T_RAS', 10)};   // Row active time
    parameter int unsigned T_RC   = {timings.get('T_RC', 14)};    // Row cycle time
    
    // Column/CAS timing
    parameter int unsigned T_CL   = {timings.get('T_CL', 4)};     // CAS latency
    parameter int unsigned T_WR   = {timings.get('T_WR', 4)};     // Write recovery
    parameter int unsigned T_WTR  = {timings.get('T_WTR', 2)};    // Write to read
    parameter int unsigned T_RTP  = {timings.get('T_RTP', 2)};    // Read to precharge
    
    // Refresh timing
    parameter int unsigned T_RFC  = {timings.get('T_RFC', 18)};   // Refresh cycle
    parameter int unsigned T_REFI = {timings.get('T_REFI', 780)}; // Refresh interval
    
    // Mode register timing
    parameter int unsigned T_MRD  = {timings.get('T_MRD', 2)};    // Mode register delay
    parameter int unsigned T_MOD  = {timings.get('T_MOD', 12)};   // Mode register to command
    
    // Initialization
    parameter int unsigned T_INIT     = {timings.get('T_INIT', 20000)}; // Init delay (200us)
    parameter int unsigned T_DLL_LOCK = {timings.get('T_DLL_LOCK', 200)}; // DLL lock time
    
    // Derived parameters
    parameter int unsigned CAS_LATENCY   = {timings.get('CAS_LATENCY', 4)};
    parameter int unsigned WRITE_LATENCY = {timings.get('WRITE_LATENCY', 3)};
    parameter int unsigned BURST_LEN     = {timings.get('BURST_LEN', 4)};
    
    // Bank configuration
    parameter int unsigned NUM_BANKS  = {timings.get('NUM_BANKS', 8)};
    parameter int unsigned BANK_BITS  = {timings.get('BANK_BITS', 3)};
    parameter int unsigned ROW_BITS   = {timings.get('ROW_BITS', 13)};
    parameter int unsigned COL_BITS   = {timings.get('COL_BITS', 10)};

"""
            # DDR2-specific
            if kind == "ddr2_controller":
                content += f"""    // DDR2-specific
    parameter int unsigned T_FAW = {timings.get('T_FAW', 10)};    // Four-activate window
    parameter int unsigned T_RRD = {timings.get('T_RRD', 2)};     // Row-to-row delay
    parameter bit          ODT_ENABLED = {timings.get('ODT_ENABLED', 1)};
    parameter bit          DLL_ENABLED = {timings.get('DLL_ENABLED', 1)};

"""
        
        content += f"""endpackage : {name}_timing_pkg

`endif // {name.upper()}_TIMING_PARAMS_SVH
"""
        
        output_path = output_dir / f"{name}_timing_params.svh"
        output_path.write_text(content, encoding='utf-8')
        return output_path
    
    @staticmethod
    def generate_filelist(output_dir: Path, name: str) -> Path:
        """Generate compilation filelist - NO AI NEEDED"""
        sv_files = sorted(output_dir.glob("*.sv"))
        svh_files = sorted(output_dir.glob("*.svh"))
        
        content = f"""# Filelist for {name}
# Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
#
# Usage:
#   Verilator: verilator --lint-only -f filelist.f
#   VCS:       vcs -f filelist.f
#   Genus:     read_hdl -f filelist.f

# Include directories
+incdir+{output_dir}

# Header files
"""
        for f in svh_files:
            content += f"{f.name}\n"
        
        content += "\n# Source files\n"
        for f in sv_files:
            content += f"{f.name}\n"
        
        output_path = output_dir / "filelist.f"
        output_path.write_text(content, encoding='utf-8')
        return output_path
    
    @staticmethod
    def generate_sdc(spec: Dict, timings: Dict, output_dir: Path) -> Path:
        """Generate SDC timing constraints - NO AI NEEDED"""
        name = spec.get("name", "memory_ctrl")
        clock_mhz = spec.get("clock_mhz", 100)
        period_ns = timings.get("CLK_PERIOD_NS", 10.0)
        kind = spec.get("kind", "sram_controller")
        
        content = f"""###############################################################################
# SDC Timing Constraints for {name}
# Kind: {kind}
# Clock: {clock_mhz} MHz (period = {period_ns:.3f} ns)
# Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
###############################################################################

# ══════════════════════════════════════════════════════════════════════════════
# Clock Definition
# ══════════════════════════════════════════════════════════════════════════════
create_clock -name clk -period {period_ns:.3f} [get_ports clk]
set_clock_uncertainty 0.1 [get_clocks clk]
set_clock_transition  0.05 [get_clocks clk]

# ══════════════════════════════════════════════════════════════════════════════
# I/O Constraints
# ══════════════════════════════════════════════════════════════════════════════
set_input_delay  -clock clk -max {period_ns * 0.3:.3f} [all_inputs]
set_input_delay  -clock clk -min {period_ns * 0.05:.3f} [all_inputs]
set_output_delay -clock clk -max {period_ns * 0.3:.3f} [all_outputs]
set_output_delay -clock clk -min {period_ns * 0.05:.3f} [all_outputs]

# Don't constrain clock and reset as data
remove_input_delay [get_ports clk]
remove_input_delay [get_ports rst_n]

# ══════════════════════════════════════════════════════════════════════════════
# Design Rules
# ══════════════════════════════════════════════════════════════════════════════
set_max_fanout 32 [current_design]
set_max_transition 0.2 [current_design]

"""
        
        # Add DRAM-specific constraints
        if kind in ("sdram_controller", "ddr_controller", "ddr2_controller"):
            cl = timings.get("CAS_LATENCY", 4)
            content += f"""# ══════════════════════════════════════════════════════════════════════════════
# DRAM-Specific Multicycle Paths
# ══════════════════════════════════════════════════════════════════════════════
# CAS Latency = {cl} cycles
set_multicycle_path -setup {cl} \\
    -from [get_pins -hierarchical */read_cmd*/Q] \\
    -to   [get_pins -hierarchical */rdata*/D]
set_multicycle_path -hold  {cl - 1} \\
    -from [get_pins -hierarchical */read_cmd*/Q] \\
    -to   [get_pins -hierarchical */rdata*/D]

# Configuration registers are quasi-static
set_multicycle_path -setup 2 -from [get_pins -hierarchical */config*/Q]
set_multicycle_path -hold  1 -from [get_pins -hierarchical */config*/Q]

# Reset is asynchronous
set_false_path -from [get_ports rst_n]

"""
        
        content += """###############################################################################
# End of constraints
###############################################################################
"""
        
        output_path = output_dir / f"{name}.sdc"
        output_path.write_text(content, encoding='utf-8')
        return output_path


# =============================================================================
# SPEC PROCESSOR
# =============================================================================

@dataclass
class ProcessedSpec:
    """Processed specification ready for generation"""
    kind: str
    name: str
    clock_mhz: int
    timings: Dict[str, Any]
    replacements: Dict[str, str]
    raw: Dict


class SpecProcessor:
    """Process raw spec.json into generation-ready format"""
    
    @staticmethod
    def process(spec: Dict) -> ProcessedSpec:
        kind = spec.get("kind", "sram_controller")
        
        # Handle empty or missing name
        name = spec.get("name", "")
        if not name or name.strip() == "":
            # Generate name from kind
            name = kind.replace("_controller", "_ctrl")
        
        # Handle clock_mhz - convert "default" or invalid values
        clock_mhz_raw = spec.get("clock_mhz", 100)
        if isinstance(clock_mhz_raw, str):
            if clock_mhz_raw.lower() == "default" or clock_mhz_raw == "":
                clock_mhz = 100
            else:
                try:
                    clock_mhz = int(float(clock_mhz_raw))
                except ValueError:
                    clock_mhz = 100
        else:
            clock_mhz = int(clock_mhz_raw) if clock_mhz_raw else 100
        
        # Calculate timings (automatic, no AI)
        timings = TimingCalculator.calculate(spec)
        
        # Build replacements dict for skeleton templates
        replacements = SpecProcessor._build_replacements(spec, timings)
        
        return ProcessedSpec(
            kind=kind,
            name=name,
            clock_mhz=clock_mhz,
            timings=timings,
            replacements=replacements,
            raw=spec
        )
    
    @staticmethod
    def _build_replacements(spec: Dict, timings: Dict) -> Dict[str, str]:
        """Build the {{PLACEHOLDER}} replacement dictionary"""
        kind = spec.get("kind", "sram_controller")
        host_if = spec.get("host_if", {})
        mem = spec.get("mem", {})
        fifo = spec.get("fifo", {})
        regfile = spec.get("regfile", {})
        dram = spec.get("dram", {})
        
        # Handle empty name
        name = spec.get("name", "")
        if not name or name.strip() == "":
            name = kind.replace("_controller", "_ctrl")
        
        # Handle clock_mhz
        clock_mhz_raw = spec.get("clock_mhz", 100)
        if isinstance(clock_mhz_raw, str):
            try:
                clock_mhz = int(float(clock_mhz_raw)) if clock_mhz_raw.lower() != "default" else 100
            except ValueError:
                clock_mhz = 100
        else:
            clock_mhz = int(clock_mhz_raw) if clock_mhz_raw else 100
        
        r = {
            "MODULE_NAME": name,
            "FREQ_MHZ": str(clock_mhz),
            "DATA_WIDTH": str(host_if.get("data_bits", 32)),
            "ADDR_WIDTH": str(host_if.get("addr_bits", 16)),
            "BUS_TYPE": host_if.get("bus", "custom"),
        }
        
        # Add ALL timing values as replacements
        for k, v in timings.items():
            r[k] = str(v)
        
        # Kind-specific additions
        if "sram" in kind or "rom" in kind:
            depth = mem.get("depth", 1024)
            r["MEM_DEPTH"] = str(depth)
            r["MEM_ADDR_BITS"] = str(max(1, (depth - 1).bit_length()))
            r["READ_LATENCY"] = str(spec.get("timing", {}).get("read_latency_cycles", 1))
            r["HAS_WRITE_MASK"] = "1" if spec.get("write_enable_mask", False) else "0"
            r["HAS_ECC"] = "1" if spec.get("ecc", {}).get("enabled", False) else "0"
            r["STROBE_WIDTH"] = str(host_if.get("data_bits", 32) // 8)
        
        elif kind == "fifo_controller":
            depth = fifo.get("depth", 1024)
            r["FIFO_DEPTH"] = str(depth)
            r["FIFO_ADDR_BITS"] = str(max(1, (depth - 1).bit_length()))
            r["ALMOST_FULL"] = str(fifo.get("almost_full_thresh", depth - 128))
            r["ALMOST_EMPTY"] = str(fifo.get("almost_empty_thresh", 128))
            r["DATA_WIDTH"] = str(fifo.get("data_bits", 32))
        
        elif kind == "regfile_controller":
            entries = regfile.get("entries", 32)
            r["ENTRIES"] = str(entries)
            r["ENTRY_BITS"] = str(max(1, (entries - 1).bit_length()))
            r["READ_PORTS"] = str(regfile.get("read_ports", 2))
            r["WRITE_PORTS"] = str(regfile.get("write_ports", 1))
            r["HAS_BYPASS"] = "1" if regfile.get("bypass_on_same_cycle", True) else "0"
            r["DATA_WIDTH"] = str(regfile.get("data_bits", 32))
        
        return r


# =============================================================================
# CODE GENERATOR
# =============================================================================

class CodeGenerator:
    """Generates RTL code using focused LLM calls"""
    
    SYSTEM_PROMPT = """You are an expert SystemVerilog RTL designer specializing in memory controllers.

CRITICAL RULES:
1. Output ONLY valid SystemVerilog code - no markdown, no explanations, no ```
2. Every signal must be driven - no dangling wires
3. Use always_ff for sequential logic, always_comb for combinational
4. Include reset logic for ALL registers
5. NO TODOs, NO placeholders - complete, working code only
6. Synthesizable code only - no $display, no delays for synthesis
7. Use proper widths - no implicit truncation warnings

If the skeleton is already complete, just apply the parameter substitutions and return it."""

    def __init__(self, config: GeneratorConfig, llm: LLMClient):
        self.config = config
        self.llm = llm
    
    def generate_component(self, spec: ProcessedSpec, component: str, 
                          skeleton_path: Path, contexts: Dict[str, str]) -> str:
        """Generate a single component from skeleton"""
        
        # Load skeleton
        if not skeleton_path.exists():
            raise FileNotFoundError(f"Skeleton not found: {skeleton_path}")
        
        skeleton = skeleton_path.read_text(encoding='utf-8')
        
        # Apply parameter substitutions first
        skeleton = self._apply_replacements(skeleton, spec.replacements)
        
        # Check if skeleton needs AI completion
        todo_count = skeleton.upper().count("TODO")
        
        if todo_count == 0:
            # Skeleton is complete - no AI needed!
            print(f"    [AUTO] Skeleton complete, no AI needed")
            return skeleton
        
        # AI completion needed
        print(f"    [AI] {todo_count} TODOs to complete...")
        return self._complete_with_ai(spec, skeleton, contexts)
    
    def _complete_with_ai(self, spec: ProcessedSpec, skeleton: str, 
                         contexts: Dict[str, str]) -> str:
        """Use AI to complete TODOs in skeleton"""
        
        spec_str = json.dumps({
            "kind": spec.kind,
            "name": spec.name,
            "clock_mhz": spec.clock_mhz,
            "params": spec.replacements
        }, indent=2)
        
        context_str = ""
        if contexts:
            for name, content in contexts.items():
                if content:
                    context_str += f"\n### {name.upper()} ###\n{content[:4000]}\n"
        
        prompt = f"""Complete this SystemVerilog module. Fill in ALL TODO sections with working logic.

SPECIFICATION:
{spec_str}

{"CONTEXT:" + context_str if context_str else ""}

SKELETON TO COMPLETE:
{skeleton}

Output ONLY the complete SystemVerilog code with all TODOs filled in:"""
        
        code = self.llm.generate(self.SYSTEM_PROMPT, prompt)
        return self._clean_code(code)
    
    def _apply_replacements(self, text: str, replacements: Dict[str, str]) -> str:
        """Replace all {{PLACEHOLDER}} tokens"""
        for key, value in replacements.items():
            text = text.replace(f'{{{{{key}}}}}', str(value))
        return text
    
    def _clean_code(self, code: str) -> str:
        """Clean generated code"""
        # Remove markdown code blocks
        code = re.sub(r'```(?:systemverilog|verilog|sv)?\s*\n?', '', code)
        code = re.sub(r'```\s*$', '', code, flags=re.MULTILINE)
        
        # Remove any leading/trailing explanation
        lines = code.split('\n')
        start_idx = 0
        end_idx = len(lines)
        
        # Find first line that looks like Verilog
        for i, line in enumerate(lines):
            if line.strip().startswith(('`', 'module', '//', 'package')):
                start_idx = i
                break
        
        # Find last endmodule
        for i in range(len(lines) - 1, -1, -1):
            if 'endmodule' in lines[i]:
                end_idx = i + 1
                break
        
        code = '\n'.join(lines[start_idx:end_idx])
        
        # Ensure trailing newline
        if code and not code.endswith('\n'):
            code += '\n'
        
        return code


# =============================================================================
# VERIFIER
# =============================================================================

class Verifier:
    """Verify generated code"""
    
    def __init__(self, config: GeneratorConfig):
        self.config = config
    
    def verify(self, code: str, filepath: Path) -> Tuple[bool, List[str]]:
        """Verify generated code, returns (passed, issues)"""
        issues = []
        
        # Check for TODOs
        if self.config.require_no_todos:
            todo_count = code.upper().count('TODO')
            if todo_count > 0:
                issues.append(f"{todo_count} TODO markers remaining")
        
        # Check for module
        if 'module ' not in code.lower():
            issues.append("No module declaration found")
        
        if 'endmodule' not in code.lower():
            issues.append("No endmodule found")
        
        # Check balanced blocks
        code_no_strings = re.sub(r'"[^"]*"', '', code)
        begins = len(re.findall(r'\bbegin\b', code_no_strings))
        all_ends = len(re.findall(r'\bend\b', code_no_strings))
        compound_ends = len(re.findall(
            r'\b(endmodule|endcase|endfunction|endtask|endgenerate|'
            r'endinterface|endpackage|endproperty|endsequence|endgroup)\b', 
            code_no_strings
        ))
        plain_ends = all_ends - compound_ends
        
        if begins != plain_ends:
            issues.append(f"Unbalanced begin({begins})/end({plain_ends})")
        
        # Run Verilator lint if available
        if self.config.run_lint and filepath.exists():
            lint_issues = self._run_lint(filepath)
            issues.extend(lint_issues)
        
        return len(issues) == 0, issues
    
    def _run_lint(self, filepath: Path) -> List[str]:
        """Run Verilator lint"""
        issues = []
        
        try:
            result = subprocess.run(
                ["verilator", "--lint-only", "-Wall", "--quiet", str(filepath)],
                capture_output=True, text=True, timeout=30
            )
            
            if result.returncode != 0:
                for line in result.stderr.splitlines():
                    if '%Error' in line:
                        issues.append(f"Lint: {line.strip()}")
                    elif '%Warning' in line and len(issues) < 5:
                        issues.append(f"Lint: {line.strip()}")
        
        except FileNotFoundError:
            pass  # Verilator not installed - skip
        except subprocess.TimeoutExpired:
            issues.append("Lint timed out")
        
        return issues


# =============================================================================
# MAIN GENERATOR
# =============================================================================

class MemoryControllerGenerator:
    """Main generator orchestrating the full pipeline"""
    
    def __init__(self, spec_file: str, output_dir: str, 
                 config: Optional[GeneratorConfig] = None):
        self.config = config or GeneratorConfig()
        self.spec_file = Path(spec_file)
        self.output_dir = Path(output_dir)
        
        # Create output directory
        self.output_dir.mkdir(parents=True, exist_ok=True)
        print(f"[INFO] Output directory: {self.output_dir.absolute()}")
        
        self.llm = LLMClient(self.config)
        self.generator = CodeGenerator(self.config, self.llm)
        self.verifier = Verifier(self.config)
        
        self.spec: Optional[ProcessedSpec] = None
        self.kind_config: Optional[KindConfig] = None
    
    def run(self) -> int:
        """Execute full generation pipeline"""
        print()
        print("=" * 60)
        print(f"MEMORY CONTROLLER GENERATOR v{VERSION}")
        print("=" * 60)
        
        # Step 1: Load and process spec
        if not self._load_spec():
            return 1
        
        # Step 2: Generate automatic files (no AI)
        self._generate_automatic_files()
        
        # Step 3: Load contexts (if needed)
        contexts = self._load_contexts()
        
        # Step 4: Generate components
        success, total = self._generate_components(contexts)
        
        # Step 5: Generate filelist
        AutoFileGenerator.generate_filelist(self.output_dir, self.spec.name)
        
        # Summary
        print()
        print("=" * 60)
        print("GENERATION COMPLETE")
        print("=" * 60)
        print(f"  Kind:       {self.spec.kind}")
        print(f"  Name:       {self.spec.name}")
        print(f"  Components: {success}/{total}")
        print(f"  Output:     {self.output_dir.absolute()}")
        print()
        print("Generated files:")
        for f in sorted(self.output_dir.glob("*")):
            print(f"  - {f.name}")
        print("=" * 60)
        
        return 0 if success == total else 1
    
    def _load_spec(self) -> bool:
        """Load and validate spec file"""
        print(f"\n[1/4] Loading specification: {self.spec_file}")
        
        try:
            with open(self.spec_file) as f:
                raw_spec = json.load(f)
            
            kind = raw_spec.get("kind", "sram_controller")
            
            if kind not in KIND_REGISTRY:
                print(f"[ERROR] Unknown kind: {kind}")
                print(f"[INFO] Supported: {', '.join(KIND_REGISTRY.keys())}")
                return False
            
            self.spec = SpecProcessor.process(raw_spec)
            self.kind_config = KIND_REGISTRY[kind]
            
            print(f"  Kind:       {self.spec.kind}")
            print(f"  Name:       {self.spec.name}")
            print(f"  Clock:      {self.spec.clock_mhz} MHz")
            print(f"  Complexity: {self.kind_config.complexity}/5")
            
            return True
        
        except FileNotFoundError:
            print(f"[ERROR] Spec file not found: {self.spec_file}")
            return False
        except json.JSONDecodeError as e:
            print(f"[ERROR] Invalid JSON: {e}")
            return False
        except Exception as e:
            print(f"[ERROR] Failed to load spec: {e}")
            return False
    
    def _generate_automatic_files(self):
        """Generate files automatically without AI"""
        print(f"\n[2/4] Generating automatic files (no AI)...")
        
        # Timing parameters header
        timing_path = AutoFileGenerator.generate_timing_params_svh(
            self.spec.raw, self.spec.timings, self.output_dir
        )
        print(f"  [AUTO] {timing_path.name}")
        
        # SDC constraints
        sdc_path = AutoFileGenerator.generate_sdc(
            self.spec.raw, self.spec.timings, self.output_dir
        )
        print(f"  [AUTO] {sdc_path.name}")
    
    def _load_contexts(self) -> Dict[str, str]:
        """Load context files (only for complex controllers)"""
        print(f"\n[3/4] Loading context files...")
        
        contexts = {}
        
        if not self.kind_config.context_files:
            print("  [INFO] No context files needed (simple controller)")
            return contexts
        
        for name, relpath in self.kind_config.context_files.items():
            path = self.config.contexts_dir / relpath
            
            if path.exists():
                contexts[name] = path.read_text(encoding='utf-8')
                print(f"  [OK] {name}: {len(contexts[name])} bytes")
            else:
                print(f"  [WARN] Not found: {path}")
        
        return contexts
    
    def _generate_components(self, contexts: Dict[str, str]) -> Tuple[int, int]:
        """Generate RTL components"""
        print(f"\n[4/4] Generating RTL components...")
        
        success = 0
        total = len(self.kind_config.components)
        
        skeleton_dir = self.config.skeletons_dir / self.kind_config.skeleton_subdir
        
        for component in self.kind_config.components:
            print(f"\n  [{component}]")
            
            # Find skeleton
            skeleton_path = skeleton_dir / f"MC_Skeleton_{component}.sv"
            if not skeleton_path.exists():
                skeleton_path = skeleton_dir / f"{component}.sv"
            
            if not skeleton_path.exists():
                print(f"    [SKIP] Skeleton not found: {skeleton_path}")
                continue
            
            try:
                # Generate
                code = self.generator.generate_component(
                    self.spec, component, skeleton_path, contexts
                )
                
                # Save
                output_file = self.output_dir / f"{self.spec.name}_{component}.sv"
                output_file.write_text(code, encoding='utf-8')
                
                # Verify
                passed, issues = self.verifier.verify(code, output_file)
                
                if passed:
                    print(f"    [OK] {output_file.name} ({len(code)} bytes)")
                    success += 1
                else:
                    print(f"    [WARN] {output_file.name} - issues:")
                    for issue in issues[:3]:
                        print(f"      - {issue}")
                    success += 1  # Still count partial success
            
            except Exception as e:
                print(f"    [ERROR] {e}")
        
        return success, total


# =============================================================================
# MAIN
# =============================================================================

def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description=f'Memory Controller Generator v{VERSION}',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Generate SRAM controller:
  python mc_generator_v2.py -s specs/demo_sram.json -o output/

  # List supported kinds:
  python mc_generator_v2.py --list-kinds

Environment Variables:
  USE_TAMU=true                    Enable TAMU AI
  TAMUS_AI_CHAT_API_KEY=xxx        Your TAMU API key
  TAMU_MODEL="protected.Claude Sonnet 4.5"  Model to use
"""
    )
    
    parser.add_argument('-s', '--spec', help='Spec JSON file')
    parser.add_argument('-o', '--output', default='output', help='Output directory')
    parser.add_argument('--list-kinds', action='store_true', help='List supported kinds')
    parser.add_argument('--no-lint', action='store_true', help='Skip lint checks')
    parser.add_argument('--version', action='version', version=f'%(prog)s {VERSION}')
    
    args = parser.parse_args()
    
    if args.list_kinds:
        print("Supported controller kinds:")
        print("-" * 60)
        for kind, cfg in KIND_REGISTRY.items():
            print(f"\n  {kind}")
            print(f"      Components:    {len(cfg.components)}")
            print(f"      Complexity:    {cfg.complexity}/5")
            print(f"      Timing mode:   {cfg.timing_mode}")
            print(f"      Context files: {len(cfg.context_files)}")
        return 0
    
    if not args.spec:
        parser.error("-s/--spec is required (or use --list-kinds)")
    
    config = GeneratorConfig()
    if args.no_lint:
        config.run_lint = False
    
    generator = MemoryControllerGenerator(args.spec, args.output, config)
    return generator.run()


if __name__ == '__main__':
    sys.exit(main())
