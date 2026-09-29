#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FHE="$(dirname "$HERE")"
OBJ="$FHE/build/obj_phase_bank"
verilator --binary --timing --assert -j "${JOBS:-4}" -Wno-fatal \
  --top-module tb_fhe_phase_bank --Mdir "$OBJ" \
  "$FHE/rtl/fhe_aloha_mem_if.sv" "$FHE/rtl/fhe_aloha_mem_top.sv" \
  "$FHE/aloha/rtl/aloha_bram_behav.sv" "$HERE/tb_fhe_phase_bank.sv"
"$OBJ/Vtb_fhe_phase_bank"
