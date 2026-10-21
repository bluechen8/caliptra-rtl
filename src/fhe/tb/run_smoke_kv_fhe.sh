#!/usr/bin/env bash
# FHE KeyVault-seed smoke at the caliptra_top_tb level (register map v2).
#
#   VeeR firmware (smoke_test_kv_fhe) triggers the TB KeyVault backdoor
#   (opcode 0xc6: a known 160-bit seed into slot 9, readable by client 2), reads
#   it through KV_RD_SEED_CTRL, runs KEYGEN and checks KEY_VALID and the command
#   preconditions. The TB asserts the seed the sampler receives equals the
#   KeyVault value.
#
#   Requires a NoABR build: the FHE KV client uses kv_read[2], which Adams Bridge
#   owns unless compiled out. So this build adds +define+CALIPTRA_NO_ADAMS_BRIDGE
#   (also exercises the newly NoABR-capable caliptra_top_tb).
#
#   SIM=vcs ./run_smoke_kv_fhe.sh [LOGN]     # default LOGN=8 (N=256); VCS required
#
# The full caliptra_top_tb does not build under the Verilator available here, so
# this defaults to VCS.
set -euo pipefail

LOGN="${1:-8}"
N=$((1 << LOGN))
SIM="${SIM:-vcs}"

if [[ "$SIM" == "vcs" && -f /ecad/tools/vlsi.bashrc ]]; then
  set +u; source /ecad/tools/vlsi.bashrc; set -u
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"        # src/fhe/tb
FHE="$(dirname "$HERE")"                                    # src/fhe
VSRC="$(cd "$FHE/../../.." && pwd)"                         # vsrc

set +u; pushd "$VSRC" >/dev/null; source ./caliptra-env.sh; popd >/dev/null; set -u
export CALIPTRA_WORKSPACE="$(dirname "$CALIPTRA_ROOT")"
export GCC_PREFIX="${CALIPTRA_GCC_PREFIX:-${GCC_PREFIX:-riscv64-unknown-elf}}"
export ALOHA_PORT="$CALIPTRA_ROOT/src/fhe/aloha"
export ALOHA_SRC="${ALOHA_SRC:-$ALOHA_PORT/vendor}"
if [[ "$SIM" == "verilator" ]]; then
  export CALIPTRA_AXI4PC_DIR="$CALIPTRA_ROOT/src/integration/tb"
fi

RUNDIR="$CALIPTRA_ROOT/fhe_kv_rundir"
MIF="$RUNDIR/mif"
mkdir -p "$MIF"

echo "== [N=$N / LOGN=$LOGN] generating golden plaintext + Aloha ROM tables =="
python3 "$ALOHA_PORT/tvgen/gen_roundtrip.py" "$LOGN" "$RUNDIR" >/dev/null

# Generate the CROM locally for every N; never use a checked-in table.
python3 "$ALOHA_PORT/vendor/Scripts/GenerateConstantsROM.py"        "$LOGN" "$MIF/TwFctrCache_RNSConsts.coe"

coe2mem() {
  [[ -f "$1" ]] || { echo "ERROR: missing ROM table: $1" >&2; return 1; }
  sed -e 's/memory_initialization_radix.*//I' \
      -e 's/memory_initialization_vector[[:space:]]*=//I' \
      -e 's/[;,]//g' "$1" | grep -viE '[^0-9a-fx[:space:]]' | grep -vE '^[[:space:]]*$' > "$2"
}
coe2mem "$MIF/TwFctrCache_RNSConsts.coe"   "$RUNDIR/fft_rns_rom.mem"

MK="$CALIPTRA_ROOT/tools/scripts/Makefile"
COMMON=(CALIPTRA_ROOT="$CALIPTRA_ROOT" TESTNAME=smoke_test_kv_fhe
        TB_VF="$CALIPTRA_ROOT/src/integration/config/caliptra_top_tb_fhe.vf"
        EXTRA_DEFS="+define+FHE_WALKER +define+CALIPTRA_NO_ADAMS_BRIDGE +define+FHE_N=$N")

echo "=== build + run smoke_test_kv_fhe ($SIM, NoABR, N=$N) ==="
LOG="$RUNDIR/smoke_kv_fhe_${SIM}.log"
make -C "$RUNDIR" -f "$MK" "${COMMON[@]}" \
  VERILATOR_RUN_ARGS="+FHE_TVDIR=$RUNDIR" "$SIM" 2>&1 | tee "$LOG"

echo "=== verdict ==="
if grep -q "\[FHE-KV-TB\] FAIL" "$LOG"; then
  echo "smoke_test_kv_fhe RESULT: FAIL (KV seed did not reach walker; see $LOG)"; exit 1
fi
if grep -q "\[FHE-KV-TB\] PASS" "$LOG" && grep -q "TESTCASE PASSED" "$LOG"; then
  echo "smoke_test_kv_fhe RESULT: PASS"
else
  echo "smoke_test_kv_fhe RESULT: FAIL (see $LOG)"; exit 1
fi
