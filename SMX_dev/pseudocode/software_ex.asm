# Copyright (c) 2026 Luca Donato, Tommaso Spagnolo, Cristina Silvano
# SPDX-License-Identifier: MIT

# Software Example for Updated SMX Unit
# =======================================
#
# This document explains how to use the updated SMX functional unit from a software perspective.
# It covers initialization, the 4-step Softmax process, and the new bit layout for the MAX/MIN/SHIFT results.
#
# Assumptions:
# a0 = ptr_in  (Pointer to input vector of int8 elements)
# a1 = ptr_out (Pointer to output vector of int8 elements)
# a2 = N       (Number of elements in the vector, must be a multiple of 8 for this unrolled loop example)
#
# --------------------------------------------------------------------------------
# Step 1: Find Global Max and Min (SMX.CONTX)
# --------------------------------------------------------------------------------
# The SMX.CONTX instruction now computes both the global maximum and the global minimum (needed for adaptive shift).
# It also calculates the adaptive shift amount based on the dynamic range (Max - Min).
#
# Instruction: smx.contx rd, rs1, rs2
#
# Inputs:
#   rs1: Packed 4x8-bit input values
#   rs2: Packed 4x8-bit input values
#   rd:  Previous running result (Accumulator for Max/Min)
#
# Output (rd):
#   The output format has changed to:
#   [31:20] : 12'b0 (Unused)
#   [19:16] : Shift Amount (4 bits, signed)
#   [15:8]  : Global Min (8 bits, signed)
#   [7:0]   : Global Max (8 bits, signed)
#
# Initialization:
#   Before the first iteration, 'rd' MUST be initialized to represent the "neutral" state for Min/Max comparisons.
#   - Max (bits [7:0]) should be initialized to the smallest possible int8 (-128 or 0x80).
#   - Min (bits [15:8]) should be initialized to the largest possible int8 (127 or 0x7F).
#   - Shift (bits [19:16]) can be 0.
#   
#   Initial rd value = 0x00007F80
#
# Pseudo-code:
    li      a3, 0x00007F80      # Initialize a3 (rd) with Min=127, Max=-128
    mv      t0, a0              # t0 = ptr_in
    mv      t1, a2              # t1 = N

.Lmax:
    lw        t2, 0(t0)           # Load 4 bytes (rs1)
    lw        t3, 4(t0)           # Load next 4 bytes (rs2)
    smx.contx a3, t2, t3          # Update Max/Min/Shift in a3
    addi      t0, t0, 8           # Increment pointer
    addi      t1, t1, -8          # Decrement count
    bnez      t1, .Lmax           # Loop
 
# After this loop, a3 contains:
#   a3[7:0]   = Global Max
#   a3[15:8]  = Global Min
#   a3[19:16] = Adaptive Shift Amount (calculated from final Max-Min)

# --------------------------------------------------------------------------------
# Step 2: Compute Sum of Exponentials (SMX.ACC)
# --------------------------------------------------------------------------------
# This step computes the sum of exp(x_i - x_max) * shift_factor.
# The unit uses the Max and Shift values computed in Step 1.
#
# Instruction: smx.acc rd, rs1, rs2
#
# Inputs:
#   rs1: Packed 4x8-bit input values (vector elements)
#   rs2: The result from Step 1 (a3), containing {Shift, Min, Max}
#   rd:  Accumulator for the sum
#
# Output (rd):
#   rd = rd + Sum(LUT1(x_i, Max, Shift))
#
# Initialization:
#   rd (accumulator) must be initialized to 0.

    li      a4, 0               # Initialize Sum Accumulator (a4) to 0
    mv      t0, a0              # Reset ptr_in
    mv      t1, a2              # Reset N

.Lsum:
    lw      t2, 0(t0)           # Load 4 bytes
    smx.acc a4, t2, a3          # Accumulate exp values. a3 holds the Max/Min/Shift context
    addi    t0, t0, 4           # Increment pointer
    addi    t1, t1, -4          # Decrement count
    bnez    t1, .Lsum           # Loop

# After this loop, a4 contains the total sum of exponentials.

# --------------------------------------------------------------------------------
# Step 3 & 4: Compute Exp and Softmax (SMX.EXP + SMX.SIGM)
# --------------------------------------------------------------------------------
# These steps are usually pipelined or executed together.
# SMX.EXP computes the exponential vector for a block of 4 inputs.
# SMX.SIGM takes that exponential vector and the global sum (from Step 2) to lookup the final result.
#
# Instruction: smx.exp rd, rs1, rs2
# Inputs:
#   rs1: Packed 4x8-bit input values
#   rs2: Context from Step 1 (a3) -> {Shift, Min, Max}
# Output:
#   rd:  Packed 4x8-bit exponential values
#
# Instruction: smx.sigm rd, rs1, rs2
# Inputs:
#   rs1: Global Sum (from Step 2, a4)
#   rs2: Exponential Vector (from smx.exp output)
# Output:
#   rd:  Packed 4x8-bit Softmax results
#
# Note: SMX.SIGM uses a 2D LUT. The Row index is derived from the Global Sum (rs1),
# and the Column index is derived from the Exp value (rs2).

    mv      t0, a0              # Reset ptr_in
    mv      t5, a1              # t5 = ptr_out
    mv      t1, a2              # Reset N

.Lexpsigm:
    lw      t2, 0(t0)           # Load 4 bytes
    smx.exp a5, t2, a3          # Compute Exp vector -> a5. Uses context a3.
    smx.sigm t3, a4, a5         # Compute Sigmoid/Softmax -> t3. Uses Sum a4 and Exp a5.
    sw      t3, 0(t5)           # Store 4 results to output
    addi    t0, t0, 4           # Increment input pointer
    addi    t5, t5, 4           # Increment output pointer
    addi    t1, t1, -4          # Decrement count
    bnez    t1, .Lexpsigm       # Loop

# --------------------------------------------------------------------------------
# Summary of Register Usage
# --------------------------------------------------------------------------------
# a0: Input Pointer
# a1: Output Pointer
# a2: Vector Length (N)
# a3: Context Register {12'b0, Shift, Min, Max} - Result of Step 1
# a4: Global Sum Accumulator - Result of Step 2
# a5: Temporary Exponential Vector - Result of Step 3, Input to Step 4
# t3: Final Result Vector

+-----------------------------------------------------------------------------------------------+
| SMX.CONTX - Find Global Max/Min & Shift                                                         |
+-----------------------------------------------------------------------------------------------+
The instruction updates the running context in 'rd' based on new inputs in 'rs1' and 'rs2'.

      31 30       ...       20 19    16 15             8 7              0
     +------------------------+--------+----------------+----------------+
rs1  |    Input Byte 3 (int8) | Byte 2 | Byte 1 (int8)  | Byte 0 (int8)  | Packed Inputs A
     +------------------------+--------+----------------+----------------+

      31 30       ...       20 19    16 15             8 7              0
     +------------------------+--------+----------------+----------------+
rs2  |    Input Byte 3 (int8) | Byte 2 | Byte 1 (int8)  | Byte 0 (int8)  | Packed Inputs B
     +------------------------+--------+----------------+----------------+

      31 30       ...       20 19    16 15             8 7              0
     +------------------------+--------+----------------+----------------+
rd   |  12'b0 (Unused/Zero)   | Shift  | Global Min (i8)| Global Max (i8)| Accumulator Context
(in) +------------------------+--------+----------------+----------------+ (Previous State)

      31 30       ...       20 19    16 15             8 7              0
     +------------------------+--------+----------------+----------------+
rd   |  12'b0 (Unused/Zero)   | Shift  | Global Min (i8)| Global Max (i8)| Accumulator Context
(out)+------------------------+--------+----------------+----------------+ (Updated State)


+-----------------------------------------------------------------------------------------------+
| SMX.ACC - Compute Sum of Exponentials                                                         |
+-----------------------------------------------------------------------------------------------+
Accumulates exp(x_i - x_max) using the context from smx.contx.

      31 30       ...       20 19    16 15             8 7              0
     +------------------------+--------+----------------+----------------+
rs1  |    Input Byte 3 (int8) | Byte 2 | Byte 1 (int8)  | Byte 0 (int8)  | Packed Vector Inputs
     +------------------------+--------+----------------+----------------+

      31 30       ...       20 19    16 15             8 7              0
     +------------------------+--------+----------------+----------------+
rs2  |   (Ignored by hardware)| Shift  | Global Min (i8)| Global Max (i8)| Context (from smx.contx)
     +------------------------+--------+----------------+----------------+

      31 30       ...       20 19    16 15             8 7              0
     +-------------------------------------------------------------------+
rd   |                        Global Sum Accumulator (int32)             | Running Sum
(in) +-------------------------------------------------------------------+

      31 30       ...       20 19    16 15             8 7              0
     +-------------------------------------------------------------------+
rd   |                  Updated Global Sum Accumulator (int32)           | Updated Sum
(out)+-------------------------------------------------------------------+


+-----------------------------------------------------------------------------------------------+
| SMX.EXP - Compute Exponential Vector                                                          |
+-----------------------------------------------------------------------------------------------+
Computes Packed Exp vector based on input and context.

      31 30       ...       20 19    16 15             8 7              0
     +------------------------+--------+----------------+----------------+
rs1  |    Input Byte 3 (int8) | Byte 2 | Byte 1 (int8)  | Byte 0 (int8)  | Packed Vector Inputs
     +------------------------+--------+----------------+----------------+

      31 30       ...       20 19    16 15             8 7              0
     +------------------------+--------+----------------+----------------+
rs2  |   (Ignored by hardware)| Shift  | Global Min (i8)| Global Max (i8)| Context (from smx.contx)
     +------------------------+--------+----------------+----------------+

      31 30       ...       20 19    16 15             8 7              0
     +------------------------+--------+----------------+----------------+
rd   |      Exp Byte 3 (int8) | Exp B2 | Exp Byte 1 (i8)| Exp Byte 0 (i8)| Packed Exp Results
     +------------------------+--------+----------------+----------------+




+-----------------------------------------------------------------------------------------------+
| SMX.SIGM - Final Softmax/Sigmoid Lookup                                                       |
+-----------------------------------------------------------------------------------------------+
Performs division/lookup using Global Sum and Exp Vector.

      31 30       ...       20 19    16 15             8 7              0
     +-------------------------------------------------------------------+
rs1  |                        Global Sum Accumulator (int32)             | Final Sum (from smx.acc)
     +-------------------------------------------------------------------+

      31 30       ...       20 19    16 15             8 7              0
     +------------------------+--------+----------------+----------------+
rs2  |      Exp Byte 3 (int8) | Exp B2 | Exp Byte 1 (i8)| Exp Byte 0 (i8)| Exp Vector (from smx.exp)
     +------------------------+--------+----------------+----------------+

      31 30       ...       20 19    16 15             8 7              0
     +------------------------+--------+----------------+----------------+
rd   | Result Byte 3 (int8)   | Res B2 | Result Byte 1  | Result Byte 0  | Packed Final Results
     +------------------------+--------+----------------+----------------+
