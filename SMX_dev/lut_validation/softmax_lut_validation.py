#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
# SPDX-License-Identifier: MIT

"""
Softmax LUT Validation Script
=============================

This script implements the Softmax function using a Look-Up Table (LUT) approach
as described in the associated research. It simulates a hardware functional unit
that operates on quantized Int8 values.

Features:
1. Generates LUTs with configurable sizes (Default: 1x101 and 11x60).
2. Simulates the hardware pipeline:
   - Input: Int8 vector (quantized from FP32).
   - Step 1: Find Max.
   - Step 2: Compute Delta = Max - Input.
   - Step 3: Look up Exp in LUT1 (1D).
   - Step 4: Accumulate Sum of Exp.
   - Step 5: Look up Sigmoid/Softmax in LUT2 (2D) using Sum and Exp.
3. Validates against FP32 Softmax (Ground Truth).
4. Computes error metrics (L1, L2, KL Divergence, Top-1 Accuracy).
"""

import argparse
import numpy as np
import os
import math
import matplotlib.pyplot as plt
from typing import Tuple, Dict, List

# -----------------------------------------------------------------------------
# Configuration & Constants
# -----------------------------------------------------------------------------

# Default LUT sizes as requested
DEFAULT_LUT1_SIZE = 101
DEFAULT_LUT2_ROWS = 11  # Denominator (Sum) index
DEFAULT_LUT2_COLS = 60  # Numerator (Exp) index

# -----------------------------------------------------------------------------
# LUT Generation
# -----------------------------------------------------------------------------

def generate_lut1d(size: int = DEFAULT_LUT1_SIZE, filename: str = "lut1d.hex") -> np.ndarray:
    """
    Generates the 1D LUT for exp(-delta).
    Maps input delta (integer) to quantized exp value.
    Assumes delta corresponds to a physical range [0, 6.4].
    """
    # Map index i -> physical value x in range [0, 6.4]
    MAX_RANGE = 6.4
    STEP = MAX_RANGE / (size - 1) if size > 1 else 1.0
    
    lut = []
    for i in range(size):
        val_fp = np.exp(-i * STEP)
        val_int = int(np.round(val_fp * 255))
        val_int = max(0, min(255, val_int))
        lut.append(val_int)
    
    arr = np.array(lut, dtype=np.uint8)
    
    # Save to hex
    if filename:
        with open(filename, 'w') as f:
            for val in arr:
                f.write(f"{val:02x}\n")
        print(f"Generated {filename} (Size: {size})")
        
    return arr

def generate_lut2d(rows: int = DEFAULT_LUT2_ROWS, cols: int = DEFAULT_LUT2_COLS, filename: str = "lut2d.hex") -> np.ndarray:
    """
    Generates the 2D LUT for Sigmoid/Softmax = Exp / Sum.
    
    Rows (j): Represents the Sum (Denominator) scaling factor.
    Cols (i): Represents the Exp value (Numerator).
    Output: Quantized (Exp / Sum).
    """
    # Mapping logic:
    # - Numerator (Exp) i maps to [0, 1.0].
    # - Denominator (Sum) j maps to [1.0, SumMax].
    
    lut = np.zeros((rows, cols), dtype=np.uint8)
    
    for r in range(rows):
        for c in range(cols):
            # Numerator: 0.0 to 1.0
            # Map col index 0..(cols-1) to 0.0..1.0
            num = c / (cols - 1) if cols > 1 else 0.0
            
            # Denominator: derived from row index r (sum >> 8)
            # den = max(r, 1.0) to approximate the sum range.
            
            den = float(r)
            if den < 1.0:
                den = 1.0
            
            val_fp = num / den
            val_int = int(np.round(val_fp * 255))
            val_int = max(0, min(255, val_int))
            
            lut[r, c] = val_int
            
    # Save to hex (Row-major)
    if filename:
        with open(filename, 'w') as f:
            for val in lut.flatten():
                f.write(f"{val:02x}\n")
        print(f"Generated {filename} (Size: {rows}x{cols})")
        
    return lut

# -----------------------------------------------------------------------------
# Simulation Logic
# -----------------------------------------------------------------------------

def quantize_int8(x_fp: np.ndarray, scale: float) -> np.ndarray:
    """Quantize FP32 to Int8."""
    # Simple symmetric quantization
    q = np.round(x_fp / scale)
    q = np.clip(q, -128, 127)
    return q.astype(np.int8)

def softmax_fp32(x: np.ndarray) -> np.ndarray:
    """Standard FP32 Softmax."""
    e_x = np.exp(x - np.max(x))
    return e_x / e_x.sum()

def softmax_lut_fu(
    q_input: np.ndarray, 
    lut1: np.ndarray, 
    lut2: np.ndarray
) -> np.ndarray:
    """
    Simulates the Hardware Functional Unit.
    
    Args:
        q_input: Int8 quantized input vector.
        lut1: 1D LUT (Exp).
        lut2: 2D LUT (Sigmoid).
        
    Returns:
        Approximated Softmax (float 0.0-1.0).
    """
    # 1. Find Max
    q_max = np.max(q_input)
    
    # 2. Compute Delta (always positive)
    # delta = q_max - q_input
    # Note: q_input is int8, result fits in uint8 (0..255)
    delta = (q_max.astype(np.int16) - q_input.astype(np.int16))
    
    # 3. LUT1 Lookup (Exp)
    # Map delta to LUT index. Fixed shift strategy for simulation.
    
    lut1_size = len(lut1)
    # Simple logic: clip to LUT size
    shift = 0
    idx1 = np.clip(delta >> shift, 0, lut1_size - 1)
    
    exp_vals = lut1[idx1] # uint8
    
    # 4. Accumulate Sum
    sum_exp = int(np.sum(exp_vals))
    
    # 5. LUT2 Lookup (Sigmoid)
    # Need row index (from sum) and col index (from exp).
    rows, cols = lut2.shape
    
    # Row Index (from Sum): r = sum >> 8
    row_idx = (sum_exp >> 8)
    row_idx = np.clip(row_idx, 0, rows - 1)
    
    # Col Index (from Exp): 0..255 -> 0..cols-1
    col_idx = (exp_vals.astype(np.int32) * (cols - 1)) // 255
    col_idx = np.clip(col_idx, 0, cols - 1)
    
    # Lookup
    softmax_u8 = lut2[row_idx, col_idx]
    
    # Convert to float 0..1
    return softmax_u8.astype(np.float32) / 255.0

def clz(x: int) -> int:
    """Count Leading Zeros for a 32-bit integer."""
    if x == 0:
        return 32
    n = 0
    if (x & 0xFFFF0000) == 0: n += 16; x <<= 16
    if (x & 0xFF000000) == 0: n += 8; x <<= 8
    if (x & 0xF0000000) == 0: n += 4; x <<= 4
    if (x & 0xC0000000) == 0: n += 2; x <<= 2
    if (x & 0x80000000) == 0: n += 1
    return n

def clz8(x: int) -> int:
    x &= 0xFF
    if x & 0x80: return 0
    if x & 0x40: return 1
    if x & 0x20: return 2
    if x & 0x10: return 3
    if x & 0x08: return 4
    if x & 0x04: return 5
    if x & 0x02: return 6
    if x & 0x01: return 7
    return 8  # empty

def softmax_lut_adaptive(
    q_input: np.ndarray, 
    lut1: np.ndarray, 
    lut2: np.ndarray
) -> np.ndarray:
    """
    Simulates the Hardware Functional Unit with Adaptive Shifting.
    
    Strategy:
    1. Compute Dynamic Range: delta_max = max(q) - min(q).
    2. Determine Shift 'k' using LZC logic.
       k = LZC(delta_max) - LZC(LUT_SIZE)
    """
    # 1. Find Max and Min
    q_max = np.max(q_input)
    q_min = np.min(q_input)
    delta_max = (int(q_max) - int(q_min)) & 0xFF
    
    # 2. Determine Shift using LZC
    lut1_size = len(lut1)
    
    # We assume 32-bit integers for LZC calculation as in hardware
    lzc_delta = clz8(delta_max)
    lzc_lut = clz8(lut1_size)
    
    # k > 0: Left Shift (Input range small)
    # k < 0: Right Shift (Input range large)
    k = lzc_delta - lzc_lut
    k = max(-8, min(7, k))
    
    # 3. Compute Delta
    delta = (q_max.astype(np.int16) - q_input.astype(np.int16))
    
    # 4. Apply Shift
    if k > 0:
        idx1 = delta << k
    elif k < 0:
        idx1 = delta >> (-k)
    else:
        idx1 = delta
        
    # Clip just in case
    idx1 = np.clip(idx1, 0, lut1_size - 1)
    
    exp_vals = lut1[idx1] # uint8
    
    # 5. Accumulate Sum
    sum_exp = int(np.sum(exp_vals))
    
    # 6. LUT2 Lookup (Sigmoid)
    rows, cols = lut2.shape
    row_idx = (sum_exp >> 8)
    row_idx = np.clip(row_idx, 0, rows - 1)
    
    col_idx = (exp_vals.astype(np.int32) * (cols - 1)) // 255
    col_idx = np.clip(col_idx, 0, cols - 1)
    
    softmax_u8 = lut2[row_idx, col_idx]
    return softmax_u8.astype(np.float32) / 255.0

# -----------------------------------------------------------------------------
# Metrics
# -----------------------------------------------------------------------------

def compute_metrics(p_true: np.ndarray, p_pred: np.ndarray) -> Dict[str, float]:
    """Compute error metrics."""
    # Avoid log(0)
    epsilon = 1e-10
    p_true = np.clip(p_true, epsilon, 1.0)
    p_pred = np.clip(p_pred, epsilon, 1.0)
    
    # Normalize pred to ensure it sums to 1 (Softmax property)
    p_pred_norm = p_pred / np.sum(p_pred)
    
    l1 = np.mean(np.abs(p_true - p_pred))
    l2 = np.sqrt(np.mean((p_true - p_pred)**2))
    
    # KL Divergence: sum(p * log(p/q))
    kl = np.sum(p_true * np.log(p_true / p_pred_norm))
    
    # Top-1 Accuracy
    top1 = 1.0 if np.argmax(p_true) == np.argmax(p_pred) else 0.0

    # Top-5 Accuracy
    # Check if the true max index is within the top 5 predicted indices
    k = 5
    if len(p_pred) < k:
        k = len(p_pred)
    
    true_idx = np.argmax(p_true)
    # argsort sorts ascending, so take the last k elements
    topk_pred_indices = np.argsort(p_pred)[-k:]
    top5 = 1.0 if true_idx in topk_pred_indices else 0.0
    
    return {"L1": l1, "L2": l2, "KL": kl, "Top1": top1, "Top5": top5}

# -----------------------------------------------------------------------------
# Plotting Utilities
# -----------------------------------------------------------------------------

def normalize_prob(p: np.ndarray, eps: float = 1e-12) -> np.ndarray:
    p = np.asarray(p, dtype=np.float64)
    s = np.sum(p)
    if s < eps:
        # fallback: uniform
        return np.ones_like(p) / len(p)
    return (p / s).astype(np.float64)

def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)

def plot_rank_curves(outdir: str, tag: str,
                     p_true: np.ndarray,
                     p_quant: np.ndarray,
                     p_lut_raw: np.ndarray,
                     p_adp_raw: np.ndarray) -> None:
    """
    Rank plot: probabilities sorted descending.
    Saves two figures: linear scale and log scale.
    Also plots LUT/adaptive both raw and normalized (dashed for raw).
    """
    ensure_dir(outdir)

    # Normalized versions for "shape" comparison
    p_lut = normalize_prob(p_lut_raw)
    p_adp = normalize_prob(p_adp_raw)

    def sorted_desc(p):
        return np.sort(p)[::-1]

    r_true  = sorted_desc(p_true)
    r_quant = sorted_desc(p_quant)
    r_lut   = sorted_desc(p_lut)
    r_adp   = sorted_desc(p_adp)

    r_lut_raw = sorted_desc(p_lut_raw)
    r_adp_raw = sorted_desc(p_adp_raw)

    x = np.arange(len(p_true))

    # Linear
    plt.figure()
    plt.plot(x, r_true,  label="FP32 (true)")
    plt.plot(x, r_quant, label="Quant ideal")
    plt.plot(x, r_lut,   label="LUT std (norm)")
    plt.plot(x, r_adp,   label="LUT adp (norm)")
    # Raw (dashed) just to see sum/scale artifacts
    plt.plot(x, r_lut_raw, linestyle="--", label="LUT std (raw)")
    plt.plot(x, r_adp_raw, linestyle="--", label="LUT adp (raw)")
    plt.xlabel("Rank (sorted by value)")
    plt.ylabel("Probability")
    plt.title(f"Rank plot (linear) - {tag}")
    plt.legend()
    plt.tight_layout()
    plt.savefig(os.path.join(outdir, f"{tag}_rank_linear.png"), dpi=200)
    plt.close()

    # Log (semilogy) to see tail
    plt.figure()
    eps = 1e-12
    plt.semilogy(x, np.clip(r_true,  eps, 1.0),  label="FP32 (true)")
    plt.semilogy(x, np.clip(r_quant, eps, 1.0), label="Quant ideal")
    plt.semilogy(x, np.clip(r_lut,   eps, 1.0), label="LUT std (norm)")
    plt.semilogy(x, np.clip(r_adp,   eps, 1.0), label="LUT adp (norm)")
    plt.semilogy(x, np.clip(r_lut_raw, eps, 1.0), linestyle="--", label="LUT std (raw)")
    plt.semilogy(x, np.clip(r_adp_raw, eps, 1.0), linestyle="--", label="LUT adp (raw)")
    plt.xlabel("Rank (sorted by value)")
    plt.ylabel("Probability (log scale)")
    plt.title(f"Rank plot (log) - {tag}")
    plt.legend()
    plt.tight_layout()
    plt.savefig(os.path.join(outdir, f"{tag}_rank_log.png"), dpi=200)
    plt.close()

def plot_abs_error_vs_rank(outdir: str, tag: str,
                           p_true: np.ndarray,
                           p_quant: np.ndarray,
                           p_lut_raw: np.ndarray,
                           p_adp_raw: np.ndarray) -> None:
    """
    Absolute error vs rank (rank defined by p_true descending).
    Uses normalized LUT/adaptive for fair "shape" error.
    """
    ensure_dir(outdir)

    order = np.argsort(p_true)[::-1]

    p_lut = normalize_prob(p_lut_raw)
    p_adp = normalize_prob(p_adp_raw)

    e_quant = np.abs(p_quant[order] - p_true[order])
    e_lut   = np.abs(p_lut[order]   - p_true[order])
    e_adp   = np.abs(p_adp[order]   - p_true[order])

    x = np.arange(len(p_true))

    plt.figure()
    plt.plot(x, e_quant, label="Quant ideal |err|")
    plt.plot(x, e_lut,   label="LUT std (norm) |err|")
    plt.plot(x, e_adp,   label="LUT adp (norm) |err|")
    plt.xlabel("Rank (by p_true)")
    plt.ylabel("Absolute error")
    plt.title(f"Abs error vs rank - {tag}")
    plt.legend()
    plt.tight_layout()
    plt.savefig(os.path.join(outdir, f"{tag}_abs_err_vs_rank.png"), dpi=200)
    plt.close()

# -----------------------------------------------------------------------------
# Main Test Loop
# -----------------------------------------------------------------------------

def run_test_case(name, x_fp, scale, lut1, lut2):
    p_true = softmax_fp32(x_fp)
    q_input = quantize_int8(x_fp, scale)
    
    # 1. LUT Softmax (Hardware Simulation)
    p_lut = softmax_lut_fu(q_input, lut1, lut2)
    m_lut = compute_metrics(p_true, p_lut)
    
    # 2. Adaptive LUT Softmax
    p_adp = softmax_lut_adaptive(q_input, lut1, lut2)
    m_adp = compute_metrics(p_true, p_adp)
    
    # 3. Ideal Softmax on Quantized Input (Quantization Baseline)
    # Dequantize: x_recon = q * scale
    x_recon = q_input.astype(np.float32) * scale
    p_quant_ideal = softmax_fp32(x_recon)
    m_quant = compute_metrics(p_true, p_quant_ideal)

    # 4. Ideal Softmax with Output Quantization (Quant Ideal Int8)
    # Simulate 8-bit output quantization: float -> uint8 -> float
    p_u8_ideal = np.clip(np.round(p_quant_ideal * 255.0), 0, 255)
    p_quant_int8 = p_u8_ideal.astype(np.float32) / 255.0
    m_quant_int8 = compute_metrics(p_true, p_quant_int8)
    
    # Return metrics + distributions (for plotting)
    dists = {
        "p_true": p_true,
        "p_quant": p_quant_ideal,
        "p_lut": p_lut,
        "p_adp": p_adp,
        "x_fp": x_fp,
        "q_input": q_input,
    }
    return m_lut, m_quant, m_quant_int8, m_adp, dists

def main():
    parser = argparse.ArgumentParser(description="Softmax LUT Validation")
    parser.add_argument("--lut1-size", type=int, default=DEFAULT_LUT1_SIZE, help="Size of 1D LUT")
    parser.add_argument("--lut2-rows", type=int, default=DEFAULT_LUT2_ROWS, help="Rows of 2D LUT")
    parser.add_argument("--lut2-cols", type=int, default=DEFAULT_LUT2_COLS, help="Cols of 2D LUT")
    parser.add_argument("--num-vecs", type=int, default=100, help="Number of test vectors")
    parser.add_argument("--vec-len", type=int, default=64, help="Vector length")
    parser.add_argument("--scale", type=float, default=0.5, help="Input quantization scale")
    args = parser.parse_args()
    
    print(f"--- Softmax LUT Validation ---")
    print(f"LUT1 Size: {args.lut1_size}")
    print(f"LUT2 Size: {args.lut2_rows}x{args.lut2_cols}")
    print(f"Scale: {args.scale}")
    
    # 1. Generate LUTs
    lut1 = generate_lut1d(args.lut1_size, "smx_lut1d.hex")
    lut2 = generate_lut2d(args.lut2_rows, args.lut2_cols, "smx_lut2d.hex")
    
    # 2. Run Tests
    np.random.seed(42)
    
    test_types = ["Gaussian", "Uniform", "Spiky"]
    # Store results for LUT, Quant Baseline and Adaptive
    results_lut = {t: {"L1": [], "L2": [], "KL": [], "Top1": [], "Top5": []} for t in test_types}
    results_quant = {t: {"L1": [], "L2": [], "KL": [], "Top1": [], "Top5": []} for t in test_types}
    results_quant8 = {t: {"L1": [], "L2": [], "KL": [], "Top1": [], "Top5": []} for t in test_types}
    results_adp = {t: {"L1": [], "L2": [], "KL": [], "Top1": [], "Top5": []} for t in test_types}
    cases = {t: [] for t in test_types}  # each element: dict with dists + metrics + kind
    
    for i in range(args.num_vecs):
        # Gaussian
        x_gauss = np.random.randn(args.vec_len).astype(np.float32)
        m_lut, m_quant, m_quant8, m_adp, dists = run_test_case("Gaussian", x_gauss, args.scale, lut1, lut2)
        for k, v in m_lut.items(): results_lut["Gaussian"][k].append(v)
        for k, v in m_quant.items(): results_quant["Gaussian"][k].append(v)
        for k, v in m_quant8.items(): results_quant8["Gaussian"][k].append(v)
        for k, v in m_adp.items(): results_adp["Gaussian"][k].append(v)
        # Keep this case for later visualization
        cases["Gaussian"].append({
            "dists": dists,
            "m_lut": m_lut,
            "m_adp": m_adp,
            "m_quant": m_quant
        })
        
        # Uniform
        x_unif = np.random.uniform(-3.0, 3.0, args.vec_len).astype(np.float32)
        m_lut, m_quant, m_quant8, m_adp, dists = run_test_case("Uniform", x_unif, args.scale, lut1, lut2)
        for k, v in m_lut.items(): results_lut["Uniform"][k].append(v)
        for k, v in m_quant.items(): results_quant["Uniform"][k].append(v)
        for k, v in m_quant8.items(): results_quant8["Uniform"][k].append(v)
        for k, v in m_adp.items(): results_adp["Uniform"][k].append(v)
        # Keep this case for later visualization
        cases["Uniform"].append({
            "dists": dists,
            "m_lut": m_lut,
            "m_adp": m_adp,
            "m_quant": m_quant
        })
        
        # Spiky (One large value)
        x_spiky = np.random.randn(args.vec_len).astype(np.float32)
        x_spiky[0] += 10.0 # Make one value very large
        m_lut, m_quant, m_quant8, m_adp, dists = run_test_case("Spiky", x_spiky, args.scale, lut1, lut2)
        for k, v in m_lut.items(): results_lut["Spiky"][k].append(v)
        for k, v in m_quant.items(): results_quant["Spiky"][k].append(v)
        for k, v in m_quant8.items(): results_quant8["Spiky"][k].append(v)
        for k, v in m_adp.items(): results_adp["Spiky"][k].append(v)
        # Keep this case for later visualization
        cases["Spiky"].append({
            "dists": dists,
            "m_lut": m_lut,
            "m_adp": m_adp,
            "m_quant": m_quant
        })
            
    # 3. Report
    print("\n--- Results (LUT Method vs Adaptive vs Quantization Baseline) ---")
    print(f"{'Type':<10} | {'Metric':<6} | {'LUT Method':<12} | {'Adaptive':<12} | {'Quant Ideal':<12} | {'Quant Int8':<12} | {'Diff(Std)':<12} | {'Diff(Adp)':<12} | {'Diff(Q8)':<12}")
    print("-" * 125)
    
    metrics_list = ["L1", "L2", "KL", "Top1", "Top5"]
    
    for t in test_types:
        print(f"[{t}]")
        for m in metrics_list:
            val_lut = np.mean(results_lut[t][m])
            val_adp = np.mean(results_adp[t][m])
            val_quant = np.mean(results_quant[t][m])
            val_quant8 = np.mean(results_quant8[t][m])
            diff_std = val_lut - val_quant
            diff_adp = val_adp - val_quant
            diff_q8  = val_quant8 - val_quant
            print(f"{'':<10} | {m:<6} | {val_lut:.6f}     | {val_adp:.6f}     | {val_quant:.6f}     | {val_quant8:.6f}     | {diff_std:+.6f}     | {diff_adp:+.6f}     | {diff_q8:+.6f}")
        print("-" * 125)

    # -------------------------------------------------------------------------
    # Visualization: pick representative cases (MED KL and WORST KL) per type
    # -------------------------------------------------------------------------
    outdir = "plots_softmax_compare"
    ensure_dir(outdir)

    for t in test_types:
        if len(cases[t]) == 0:
            continue

        # Use KL of LUT std (you can switch to adaptive if you prefer)
        kls = np.array([c["m_lut"]["KL"] for c in cases[t]], dtype=np.float64)
        kl_mean = float(np.mean(kls))

        idx_med = int(np.argmin(np.abs(kls - kl_mean)))
        idx_worst = int(np.argmax(kls))

        for label, idx in [("MED", idx_med), ("WORST", idx_worst)]:
            c = cases[t][idx]
            d = c["dists"]

            tag = f"{t}_{label}_idx{idx}_KL{c['m_lut']['KL']:.3f}"
            # Make a subfolder per type for cleanliness
            subdir = os.path.join(outdir, t)
            ensure_dir(subdir)

            # 1) Rank plots (linear + log)
            plot_rank_curves(
                outdir=subdir,
                tag=tag,
                p_true=d["p_true"],
                p_quant=d["p_quant"],
                p_lut_raw=d["p_lut"],
                p_adp_raw=d["p_adp"]
            )

            # 2) Abs error vs rank (by p_true)
            plot_abs_error_vs_rank(
                outdir=subdir,
                tag=tag,
                p_true=d["p_true"],
                p_quant=d["p_quant"],
                p_lut_raw=d["p_lut"],
                p_adp_raw=d["p_adp"]
            )

    print(f"\nSaved plots under: {outdir}/")
    
    # 3. Run Tests with Multiple Scales & Adaptive Method
    scales_to_test = [0.064, 0.25, 0.5, 1.0]
    
    print("\n--- Scale Mismatch & Mitigation Analysis ---")
    print(f"{'Type':<10} | {'Scale':<8} | {'Method':<12} | {'L1':<10} | {'KL':<10} | {'Top1':<10} | {'Top5':<10}")
    print("-" * 90)
    
    np.random.seed(42)
    
    for t_type in test_types:
        for s in scales_to_test:
            res_std = {"L1": [], "KL": [], "Top1": [], "Top5": []}
            res_adp = {"L1": [], "KL": [], "Top1": [], "Top5": []}
            
            for i in range(args.num_vecs):
                if t_type == "Gaussian":
                    x = np.random.randn(args.vec_len).astype(np.float32)
                elif t_type == "Uniform":
                    x = np.random.uniform(-3.0, 3.0, args.vec_len).astype(np.float32)
                elif t_type == "Spiky":
                    x = np.random.randn(args.vec_len).astype(np.float32)
                    x[0] += 10.0
                
                p_true = softmax_fp32(x)
                q = quantize_int8(x, s)
                
                # Standard
                p_std = softmax_lut_fu(q, lut1, lut2)
                m_std = compute_metrics(p_true, p_std)
                res_std["L1"].append(m_std["L1"])
                res_std["KL"].append(m_std["KL"])
                res_std["Top1"].append(m_std["Top1"])
                res_std["Top5"].append(m_std["Top5"])
                
                # Adaptive
                p_adp = softmax_lut_adaptive(q, lut1, lut2)
                m_adp = compute_metrics(p_true, p_adp)
                res_adp["L1"].append(m_adp["L1"])
                res_adp["KL"].append(m_adp["KL"])
                res_adp["Top1"].append(m_adp["Top1"])
                res_adp["Top5"].append(m_adp["Top5"])
                
            # Print Standard
            l1 = np.mean(res_std["L1"])
            kl = np.mean(res_std["KL"])
            top1 = np.mean(res_std["Top1"])
            top5 = np.mean(res_std["Top5"])
            note = "(Matched)" if abs(s - 0.064) < 1e-3 else ""
            print(f"{t_type:<10} | {s:<8} | {'Standard':<12} | {l1:.6f}   | {kl:.6f}   | {top1:.6f}   | {top5:.6f}   {note}")
            
            # Print Adaptive
            l1 = np.mean(res_adp["L1"])
            kl = np.mean(res_adp["KL"])
            top1 = np.mean(res_adp["Top1"])
            top5 = np.mean(res_adp["Top5"])
            print(f"{'':<10} | {s:<8} | {'Adaptive':<12} | {l1:.6f}   | {kl:.6f}   | {top1:.6f}   | {top5:.6f}")
            print("-" * 90)

if __name__ == "__main__":
    main()
