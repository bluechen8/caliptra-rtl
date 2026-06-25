#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build + run the fhe_top unit testbench with Verilator. Run from src/fhe/.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf obj_dir
verilator --binary --timing -Wno-lint -Wno-style -Wno-fatal --top-module fhe_top_tb \
  +incdir+rtl \
  rtl/fhe_params_pkg.sv rtl/fhe_1r1w_ram.sv rtl/fhe_mem_if.sv rtl/fhe_mem_top.sv \
  rtl/fhe_ahb_slv_sif.sv rtl/fhe_ctrl.sv rtl/fhe_top.sv \
  tb/fhe_top_tb.sv
./obj_dir/Vfhe_top_tb
