# verilog_generator_agent.py
def generate_verilog(spec_sheet):
    # Load skeleton
    with open('skeletons/ddr2_controller_skeleton.v') as f:
        skeleton = f.read()
    
    # Load RTL building blocks
    rtl_blocks = load_rtl_blocks('rtl_blocks/')
    
    # Construct prompt
    prompt = f"""
You are an expert Verilog designer. Generate a complete DDR2 SDRAM controller.

SPECIFICATION:
{json.dumps(spec_sheet, indent=2)}

SKELETON CODE:
{skeleton}

AVAILABLE RTL BUILDING BLOCKS:
{rtl_blocks}

REQUIREMENTS:
1. Fill in all /* IMPLEMENT */ sections
2. Replace /* SPEC: field.name */ with actual values from specification
3. Follow SystemVerilog best practices
4. Ensure all timing parameters are correctly enforced
5. Implement complete DDR2 initialization sequence per JEDEC standard

Generate the complete Verilog code:
"""
    
    response = openai.ChatCompletion.create(
        model="gpt-4-turbo",  # or your chosen model
        messages=[
            {"role": "system", "content": "You are an expert Verilog RTL designer."},
            {"role": "user", "content": prompt}
        ],
        temperature=0.2  # Lower temperature for more deterministic output
    )
    
    verilog_code = extract_code_from_response(response)
    return verilog_code
