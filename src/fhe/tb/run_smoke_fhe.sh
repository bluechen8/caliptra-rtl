#!/usr/bin/env bash
# Stage-B' 2c-step-3: end-to-end FHE smoke at the caliptra_top_tb level.
#
#   VeeR firmware (smoke_test_fhe) drives the FHE AHB registers + DMA pointers
#   and runs KEYGEN -> ENCRYPT -> DECRYPT on the REAL Aloha datapath; the
#   ciphertext rounds through the dedicated FHE DMA (fhe_m_axi_*) to a behavioral
#   AXI DRAM model in caliptra_top_tb, which backdoor-checks recovered ~= input.
#
#   ./run_smoke_fhe.sh [LOGN]          # default LOGN=8 (N=256)
#   SIM=vcs ./run_smoke_fhe.sh         # use VCS instead of Verilator
#
# NOTE (environment): the full caliptra_top_tb does NOT build under the
# Verilator available here (5.022): the base SoC BFM uses process::self()/fork
# and force/release on VeeR input ports, which this Verilator rejects
# (pre-existing, unrelated to FHE). Run on a host with VCS/Xcelium, or a
# Verilator new enough for process::self(). The FHE datapath itself is proven
# green standalone by src/fhe/tb/run_fhe_top_dma_tb.sh.
set -euo pipefail

LOGN="${1:-8}"
N=$((1 << LOGN))
SIM="${SIM:-verilator}"

# VCS toolchain (Synopsys) — sourced before the rv32 firmware toolchain so the
# latter's bin still wins for riscv64-unknown-elf-*. Skipped for SIM=verilator.
if [[ "$SIM" == "vcs" && -f /ecad/tools/vlsi.bashrc ]]; then
  set +u; source /ecad/tools/vlsi.bashrc; set -u
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"        # src/fhe/tb
FHE="$(dirname "$HERE")"                                    # src/fhe
VSRC="$(cd "$FHE/../../.." && pwd)"                         # vsrc (holds caliptra-env.sh)

# Single source of truth for CALIPTRA_ROOT, the caliptra_prim prefix, the real
# Axi4PC dir, and the rv32 multilib firmware toolchain (PATH + CALIPTRA_GCC_PREFIX):
# source vsrc/caliptra-env.sh rather than re-deriving them here (avoids drift).
set +u; pushd "$VSRC" >/dev/null; source ./caliptra-env.sh; popd >/dev/null; set -u
export CALIPTRA_WORKSPACE="$(dirname "$CALIPTRA_ROOT")"
export GCC_PREFIX="${CALIPTRA_GCC_PREFIX:-${GCC_PREFIX:-riscv64-unknown-elf}}"

# FHE-specific deltas not covered by caliptra-env.sh:
export ALOHA_PORT="$CALIPTRA_ROOT/src/fhe/aloha"
export ALOHA_SRC="${ALOHA_SRC:-$ALOHA_PORT/vendor}"
# caliptra-env.sh sets CALIPTRA_AXI4PC_DIR to the real ARM checker (BP063), used by
# VCS/Xcelium. Verilator instead uses the src/integration/tb/Axi4PC.sv stub (empty
# under `ifdef VERILATOR; the BP063 one would error). Override only for Verilator.
if [[ "$SIM" == "verilator" ]]; then
  export CALIPTRA_AXI4PC_DIR="$CALIPTRA_ROOT/src/integration/tb"
fi

RUNDIR="$CALIPTRA_ROOT/fhe_rundir"
MIF="$RUNDIR/mif"
mkdir -p "$MIF"

echo "== [N=$N / LOGN=$LOGN] generating golden plaintext + Aloha ROM tables =="
# Golden round-trip vectors -> $RUNDIR/input.txt (TB preloads + checks this).
python3 "$ALOHA_PORT/tvgen/gen_roundtrip.py" "$LOGN" "$RUNDIR" >/dev/null

# Aloha FFT/RNS twiddle ROMs (.coe -> .mem) the ComputeCore $readmemh's from cwd.
if [[ "$N" == 8192 ]]; then
  SRCMIF="$ALOHA_SRC/Aloha-HE_Common/MemoryInitializationFiles"
  cp "$SRCMIF/TwFctrCache_RNSConsts.coe"   "$MIF/" 2>/dev/null || true
  cp "$SRCMIF/FFTStoredTwiddleFactors.coe" "$MIF/" 2>/dev/null || true
else
  python3 "$ALOHA_PORT/vendor/Scripts/GenerateConstantsROM.py"        "$LOGN" "$MIF/TwFctrCache_RNSConsts.coe"
  python3 "$ALOHA_PORT/vendor/Scripts/GenerateStoredFFTTwiddleFct.py" "$LOGN" "$MIF/FFTStoredTwiddleFactors.coe"
fi
coe2mem() {
  [[ -f "$1" ]] || return 0
  sed -e 's/memory_initialization_radix.*//I' \
      -e 's/memory_initialization_vector[[:space:]]*=//I' \
      -e 's/[;,]//g' "$1" | grep -viE '[^0-9a-fx[:space:]]' | grep -vE '^[[:space:]]*$' > "$2"
}
coe2mem "$MIF/TwFctrCache_RNSConsts.coe"   "$RUNDIR/fft_rns_rom.mem"
coe2mem "$MIF/FFTStoredTwiddleFactors.coe" "$RUNDIR/fft_all_twiddle_rom.mem"

# FREERUN=1 runs the C'-2 free-run PRNG self-serve test (CSRNG -> ENTSEED/RESEED_REQ
# -> release the enforced first-encrypt stall) instead of the base smoke.
TESTNAME="${TESTNAME:-smoke_test_fhe}"
[[ -n "${FREERUN:-}" ]] && TESTNAME=smoke_test_fhe_freerun

MK="$CALIPTRA_ROOT/tools/scripts/Makefile"
COMMON=(CALIPTRA_ROOT="$CALIPTRA_ROOT" TESTNAME="$TESTNAME"
        TB_VF="$CALIPTRA_ROOT/src/integration/config/caliptra_top_tb_fhe.vf"
        EXTRA_DEFS="+define+FHE_WALKER +define+FHE_N=$N")

echo "=== build + run $TESTNAME ($SIM, N=$N) ==="
LOG="$RUNDIR/smoke_fhe_${SIM}.log"
make -C "$RUNDIR" -f "$MK" "${COMMON[@]}" \
  VERILATOR_RUN_ARGS="+FHE_TVDIR=$RUNDIR" "$SIM" 2>&1 | tee "$LOG"

echo "=== verdict ==="
if grep -q "FHE DMA round-trip: PASS" "$LOG" && grep -q "TESTCASE PASSED" "$LOG"; then
  echo "$TESTNAME RESULT: PASS"
else
  echo "$TESTNAME RESULT: FAIL (see $LOG)"; exit 1
fi
