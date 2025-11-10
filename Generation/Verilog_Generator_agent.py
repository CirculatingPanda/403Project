# verilog_generator.py
import os
import json
from openai import OpenAI
from dotenv import load_dotenv

# --- Step 1: Setup ---
# Load environment variables from a .env file (for your OPENAI_API_KEY)
load_dotenv()

# Initialize the OpenAI client
# The API key is automatically picked up from the OPENAI_API_KEY environment variable
try:
    client = OpenAI()
except Exception as e:
    print(f"Error initializing OpenAI client: {e}")
    print("Please make sure your OPENAI_API_KEY is set as an environment variable.")
    exit()

# --- Step 2: Helper Functions ---

def load_file_content(filepath):
    """Safely loads content from a file."""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return f.read()
    except FileNotFoundError:
        print(f"Warning: File not found at {filepath}. Skipping.")
        return ""

def load_rtl_blocks(directory):
    """Loads all .v files in a directory and returns their content as a single string."""
    blocks_text = "--- START OF AVAILABLE RTL BLOCKS ---\n"
    if not os.path.isdir(directory):
        print(f"Warning: RTL blocks directory not found at {directory}.")
        return ""
        
    for filename in os.listdir(directory):
        if filename.endswith('.v') or filename.endswith('.sv'):
            filepath = os.path.join(directory, filename)
            blocks_text += f"\n--- Block: {filename} ---\n"
            blocks_text += load_file_content(filepath)
            blocks_text += "\n"
    blocks_text += "--- END OF AVAILABLE RTL BLOCKS ---\n"
    return blocks_text

def extract_code_from_response(response_content):
    """Extracts Verilog code from a response, assuming it's in a markdown block."""
    # The model often returns code inside ```verilog ... ``` blocks
    if '```verilog' in response_content:
        start = response_content.find('```verilog') + len('```verilog\n')
        end = response_content.rfind('```')
        return response_content[start:end].strip()
    # Fallback if no markdown block is found
    return response_content.strip()

# --- Step 3: The Core Generation Logic ---

def generate_verilog_controller(spec_sheet, skeleton_path, rtl_blocks_path, context_files_paths):
    """
    Generates a Verilog controller using an LLM with provided context.
    
    Args:
        spec_sheet (dict): The specification for the controller.
        skeleton_path (str): Path to the Verilog skeleton file.
        rtl_blocks_path (str): Path to the directory of RTL building blocks.
        context_files_paths (list): List of paths to supplemental context files.
    """
    # Load all context materials
    skeleton = load_file_content(skeleton_path)
    rtl_blocks = load_rtl_blocks(rtl_blocks_path)
    
    # Load supplemental context (e.g., JEDEC text, full example)
    # This is our "poor man's RAG" - we are being selective.
    supplemental_context = ""
    for path in context_files_paths:
        filename = os.path.basename(path)
        supplemental_context += f"--- Context from {filename} ---\n"
        supplemental_context += load_file_content(path) + "\n\n"

    # Construct the detailed prompt
    prompt = f"""
You are a world-class senior Verilog RTL designer specializing in memory controllers.
Your task is to generate a complete, synthesizable DDR2 SDRAM controller based on the provided materials.

**1. PRIMARY SPECIFICATION (DDR2 Parameters):**
This is the ground truth for parameters.
```json
{json.dumps(spec_sheet, indent=2)}