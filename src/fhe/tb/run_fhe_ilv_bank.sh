#!/usr/bin/env bash
# fhe_ilv_bank (four 1RW sub-banks, XOR-fold mapping, one-entry write buffer)
# against the ideal one-read/one-write array contract. Expect: "tb_fhe_ilv_bank: PASS".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FHE="$(dirname "$HERE")"
OBJ="${OBJ_DIR:-$FHE/build/obj_ilv_bank}"
verilator --binary --timing --assert -j "${JOBS:-4}" -Wno-fatal \
  --top-module tb_fhe_ilv_bank --Mdir "$OBJ" \
  "$FHE/rtl/fhe_aloha_mem_if.sv" "$FHE/rtl/fhe_ilv_bank.sv" "$FHE/rtl/fhe_aloha_mem_top.sv" \
  "$HERE/tb_fhe_ilv_bank.sv"
"$OBJ/Vtb_fhe_ilv_bank"
