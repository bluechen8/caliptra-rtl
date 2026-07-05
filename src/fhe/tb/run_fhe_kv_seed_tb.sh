#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build + run the C'-1a fhe_kv_seed unit testbench with Verilator. Run from src/fhe/.
set -euo pipefail
cd "$(dirname "$0")/.."

KV_RTL=../../keyvault/rtl

rm -rf obj_dir_kvseed
verilator --binary --timing -Wno-lint -Wno-style -Wno-fatal \
  --top-module fhe_kv_seed_tb --Mdir obj_dir_kvseed \
  +incdir+rtl +incdir+$KV_RTL \
  $KV_RTL/kv_defines_pkg.sv \
  rtl/fhe_kv_seed.sv \
  tb/fhe_kv_seed_tb.sv
./obj_dir_kvseed/Vfhe_kv_seed_tb
