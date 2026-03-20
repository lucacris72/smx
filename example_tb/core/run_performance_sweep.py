#!/usr/bin/env python3
import subprocess
import sys
import os
import re
import csv
import shutil
from pathlib import Path
try:
    import matplotlib.pyplot as plt
    MATPLOTLIB_AVAILABLE = True
except ImportError:
    MATPLOTLIB_AVAILABLE = False
import numpy as np

# Configuration
N_SWEEP = [8, 16, 32, 64, 128, 256, 512, 1024]
OUTPUT_CSV = "softmax_performance.csv"
OUTPUT_PLOT = "softmax_performance.png"
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
LUT_GEN_SCRIPT = REPO_ROOT / "SMX_dev" / "src" / "gen_c_luts.py"
LUT_SOURCE_DIR = LUT_GEN_SCRIPT.parent
LUT_FILES = ("smx_lut1d.hex", "smx_lut2d.hex")

def run_command(cmd, capture_output=False):
    # print(f"Running: {cmd}")
    if capture_output:
        try:
            return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError as e:
            print(f"Error running command: {cmd}")
            print(e.output)
            sys.exit(1)
    else:
        try:
            subprocess.check_call(cmd, shell=True)
        except subprocess.CalledProcessError as e:
            print(f"Error running command: {e}")
            sys.exit(1)

def parse_cycles(output):
    fp32 = None
    smx = None
    sw = None
    
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("FP32 Cycles:"):
            fp32 = int(line.split(":")[1].strip())
        elif line.startswith("SMX  Cycles:"):
            smx = int(line.split(":")[1].strip())
        elif line.startswith("SW Model Cycles:"):
            sw = int(line.split(":")[1].strip())
            
    return fp32, smx, sw

def ensure_lut_hex_files():
    print("Generating SMX LUT hex files...")

    try:
        subprocess.check_call([sys.executable, str(LUT_GEN_SCRIPT)])
    except subprocess.CalledProcessError as e:
        print(f"Error running LUT generator: {e}")
        sys.exit(1)

    for lut_name in LUT_FILES:
        src = LUT_SOURCE_DIR / lut_name
        dst = SCRIPT_DIR / lut_name
        if not src.exists():
            print(f"Error: Expected LUT file was not generated: {src}")
            sys.exit(1)
        shutil.copy2(src, dst)

def main():
    print("========================================")
    print("    SOFTMAX PERFORMANCE SWEEP JOB")
    print("========================================")

    ensure_lut_hex_files()
    
    results = [] # List of tuples (N, fp32, smx, sw)
    
    for n in N_SWEEP:
        print(f"Testing N = {n}...")

        # Force a rebuild in a single make invocation so the selected N is
        # preserved for both the ELF and the derived HEX image.
        build_cmd = f"make -B custom/softmax_comparison.hex CUSTOM_GCC_FLAGS='-DN={n}'"
        run_command(build_cmd)

        # 2. Run Simulation
        sim_cmd = "make softmax-comparison-run"
        output = run_command(sim_cmd, capture_output=True)

        # 3. Parse Results
        fp32, smx, sw = parse_cycles(output)
        
        if fp32 is None or smx is None or sw is None:
            print(f"Error: Could not parse cycles for N={n}")
            continue
            
        print(f"  -> FP32: {fp32}, SMX: {smx}, SW: {sw}")
        results.append({
            'N': n,
            'FP32': fp32,
            'SMX': smx,
            'SW_Int8': sw
        })
        
    # ------------------------------------------------
    # Save to CSV
    # ------------------------------------------------
    print(f"\nSaving results to {OUTPUT_CSV}...")
    with open(OUTPUT_CSV, 'w', newline='') as csvfile:
        fieldnames = ['N', 'FP32', 'SMX', 'SW_Int8']
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        for row in results:
            writer.writerow(row)
            
    # ------------------------------------------------
    # Plotting
    # ------------------------------------------------
    if MATPLOTLIB_AVAILABLE:
        print(f"Generating plot to {OUTPUT_PLOT}...")
        
        n_vals = [r['N'] for r in results]
        fp32_vals = [r['FP32'] for r in results]
        smx_vals = [r['SMX'] for r in results]
        sw_vals = [r['SW_Int8'] for r in results]
        
        # Speedup calculation
        speedup_vs_fp32 = [f/s for f, s in zip(fp32_vals, smx_vals)]
        speedup_vs_sw = [w/s for w, s in zip(sw_vals, smx_vals)]
        
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 10))
        
        # Subplot 1: Absolute Cycles (Log Scale)
        ax1.plot(n_vals, fp32_vals, 'o--', label='FP32 (SoftFloat)', color='red')
        ax1.plot(n_vals, sw_vals, 's--', label='SW Model (Int8)', color='blue')
        ax1.plot(n_vals, smx_vals, '^-', label='SMX Accelerator', color='green', linewidth=2)
        
        ax1.set_title('Softmax Performance: Cycles vs Vector Dimension')
        ax1.set_xlabel('Vector Dimension (N)')
        ax1.set_ylabel('Cycles (Log Scale)')
        ax1.set_yscale('log')
        ax1.grid(True, which="both", ls="-", alpha=0.5)
        ax1.legend()
        ax1.set_xticks(n_vals)
        
        # Subplot 2: Speedup
        ax2.plot(n_vals, speedup_vs_fp32, 'o-', label='Speedup vs FP32', color='purple')
        ax2.plot(n_vals, speedup_vs_sw, 's-', label='Speedup vs SW Int8', color='orange')
        
        ax2.set_title('SMX Accelerator Speedup')
        ax2.set_xlabel('Vector Dimension (N)')
        ax2.set_ylabel('Speedup Factor (x)')
        ax2.grid(True, which="both", ls="-", alpha=0.5)
        ax2.legend()
        ax2.set_xticks(n_vals)
        
        plt.tight_layout()
        plt.savefig(OUTPUT_PLOT)
    else:
        print("Matplotlib not found. Skipping plot generation.")

    print("Done!")

if __name__ == "__main__":
    main()
