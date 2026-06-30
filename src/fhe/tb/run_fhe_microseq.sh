#!/usr/bin/env bash
# Stage-B' 2a: build + run the FHE microsequencer trace-equivalence test.
# Checks the walker emits the keygen/encrypt(L=1,L=2)/decrypt(L=1) instruction
# + seed traces matching the TB's own ins_* builders. ~seconds under Verilator.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FHE="$(dirname "$HERE")"
OBJ="${OBJ_DIR:-/tmp/obj_fhe_microseq}"
rm -rf "$OBJ"
verilator --binary \
  -Wno-style -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
  --top-module tb_fhe_microseq --Mdir "$OBJ" \
  "$FHE/rtl/fhe_params_pkg.sv" "$FHE/rtl/fhe_microseq.sv" "$HERE/tb_fhe_microseq.sv" \
  -o sim_msq
"$OBJ/sim_msq"
