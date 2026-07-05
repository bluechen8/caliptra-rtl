#!/usr/bin/env bash
# Stage-B' 2c-step-2: build + run the fhe_top + FHE-DMA round-trip unit TB.
#
#   ./run_fhe_top_dma_tb.sh [LOGN]      # default LOGN=8 (N=256)
#
# fhe_top is built with +define+FHE_WALKER so it instantiates fhe_microseq +
# ComputeCore + fhe_dma (the dedicated DMA reusing axi_mgr_rd/axi_mgr_wr) and
# exposes an AXI4 manager port. The TB drives the AHB register block (seeds /
# scales / CONFIG / 4 DMA pointer regs + CMD) and backs the manager with a
# behavioral AXI subordinate DRAM model; keygen->encrypt->decrypt round-trips
# the ciphertext through real AXI bursts and checks recovered ~= input.
#
# Expect: "fhe_top_dma_tb RESULT: PASS".
set -euo pipefail

LOGN="${1:-8}"
N=$((1 << LOGN))

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # src/fhe/tb
FHE="$(dirname "$HERE")"                                  # src/fhe
export ALOHA_PORT="$FHE/aloha"
export ALOHA_SRC="${ALOHA_SRC:-$ALOHA_PORT/vendor}"
export CALIPTRA_ROOT="$(cd "$FHE/../.." && pwd)"          # caliptra repo root
VERILATOR="${VERILATOR:-$(command -v verilator || echo /scratch/boru/chipyard/.conda-env/bin/verilator)}"

TOP=fhe_top_dma_tb
FLIST="$HERE/${TOP}.f"
# All build/run artifacts go under src/fhe/build/ (gitignored) -- never under tb/.
BUILD="$FHE/build"
WORK="$BUILD/dmaN$N"
MIF="$WORK/mif"
OBJ_DIR="$BUILD/obj_dir_$TOP"
LOG="$BUILD/${TOP}.log"
mkdir -p "$MIF"

echo "== [N=$N / LOGN=$LOGN] regenerating ROM tables + plaintext =="
if [[ "$N" == 8192 ]]; then
  MIF="$ALOHA_SRC/Aloha-HE_Common/MemoryInitializationFiles"
else
  python3 "$ALOHA_PORT/vendor/Scripts/GenerateConstantsROM.py"        "$LOGN" "$MIF/TwFctrCache_RNSConsts.coe"
  python3 "$ALOHA_PORT/vendor/Scripts/GenerateStoredFFTTwiddleFct.py" "$LOGN" "$MIF/FFTStoredTwiddleFactors.coe"
fi
python3 "$ALOHA_PORT/tvgen/gen_roundtrip.py" "$LOGN" "$WORK" >/dev/null

# KV_ONLY=1 builds the secure config (FHE_KV_SEED_ONLY): the plaintext KGSEED
# register path is compiled out and KeyVault is forced as the sole keygen-seed
# source. It implies +KVSEED (must provision + read the KV seed to work).
EXTRA_DEF=""
if [[ -n "${KV_ONLY:-}" ]]; then EXTRA_DEF="-DFHE_KV_SEED_ONLY"; export KVSEED=1; fi

echo "=== build $TOP (N=$N) ${EXTRA_DEF:+[$EXTRA_DEF]} ==="
[[ -n "${CLEAN:-}" ]] && rm -rf "$OBJ_DIR"
"$VERILATOR" --binary -j 0 \
  --timing --assert \
  --top-module "$TOP" \
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
  -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-SELRANGE \
  -Wno-LATCH -Wno-IMPLICIT -Wno-UNSIGNED -Wno-CMPCONST -Wno-ASCRANGE \
  -Wno-PINMISSING -Wno-WIDTHCONCAT -Wno-GENUNNAMED -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
  -DFHE_WALKER -DFHE_N="$N" $EXTRA_DEF \
  --Mdir "$OBJ_DIR" \
  -f "$FLIST" \
  -o "V$TOP" \
  2>&1 | tee "$LOG"

# Rundir with the .coe->.mem ROM init the Aloha core $readmemh's (depth-5, under build/).
RUNDIR="$BUILD/.run_$TOP/a/b/c/d"
mkdir -p "$RUNDIR"
coe2mem() {
  [[ -f "$1" ]] || return 0
  sed -e 's/memory_initialization_radix.*//I' \
      -e 's/memory_initialization_vector[[:space:]]*=//I' \
      -e 's/[;,]//g' "$1" | grep -viE '[^0-9a-fx[:space:]]' | grep -vE '^[[:space:]]*$' > "$2"
}
coe2mem "$MIF/TwFctrCache_RNSConsts.coe"   "$RUNDIR/fft_rns_rom.mem"
coe2mem "$MIF/FFTStoredTwiddleFactors.coe" "$RUNDIR/fft_all_twiddle_rom.mem"

echo "=== running (cwd=$RUNDIR) ==="
# KVSEED=1 sources the keygen root seed from a modeled KeyVault (C'-1b) and
# asserts the walker's effective seed == the KV value (KGSEED regs held wrong).
PLUSARGS=""
[[ -n "${KVSEED:-}" ]] && PLUSARGS="+KVSEED"
( cd "$RUNDIR" && "$OBJ_DIR/V$TOP" +TVDIR="$WORK" $PLUSARGS ) 2>&1 | tee -a "$LOG"

echo "=== verdict ==="
if grep -qiE "assertion failed|%Error|Failed opening file|TIMEOUT|RESULT: FAIL" "$LOG"; then
  echo "$TOP RESULT: FAIL (see $LOG)"; exit 1
fi
grep -q "$TOP RESULT: PASS" "$LOG" || { echo "$TOP RESULT: FAIL (see $LOG)"; exit 1; }
echo "$TOP RESULT: PASS"
