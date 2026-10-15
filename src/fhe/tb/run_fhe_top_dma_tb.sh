#!/usr/bin/env bash
# Build + run the fhe_top unit TB (register map v2).
#
#   ./run_fhe_top_dma_tb.sh [LOGN]      # default LOGN=8 (N=256)
#
# fhe_top is built with +define+FHE_WALKER. The TB plays firmware: KeyVault
# seed read, CONFIG and slot bases, commands, and the XFER_* stream against a
# TB memory. It checks round trips, recovery, refresh, the single-seed stream
# and command preconditions. Options: LIMBS2=1 (two-limb ciphertexts and the
# N=256 key golden), FFT_ON_THE_FLY=1, STREAM_STALLS=1, MNIST_DIR=<dir>,
# DMA_STREAM=1 (bypass-AES segments through Caliptra's axi_dma and an AXI
# memory over the same TB memory; adds the lease/address/error/abort tests).
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
OBJ_DIR="${OBJ_DIR:-$BUILD/obj_dir_$TOP}"
LOG="$BUILD/${TOP}.log"
mkdir -p "$MIF"

echo "== [N=$N / LOGN=$LOGN] regenerating ROM tables + plaintext =="
# Generate both tables locally for every N; never use a checked-in CROM.
python3 "$ALOHA_PORT/vendor/Scripts/GenerateConstantsROM.py"        "$LOGN" "$MIF/TwFctrCache_RNSConsts.coe"
python3 "$ALOHA_PORT/vendor/Scripts/GenerateStoredFFTTwiddleFct.py" "$LOGN" "$MIF/FFTStoredTwiddleFactors.coe"

python3 "$ALOHA_PORT/tvgen/gen_roundtrip.py" "$LOGN" "$WORK" >/dev/null

EXTRA_DEF=""
[[ "${FFT_ON_THE_FLY:-0}" == 1 ]] && EXTRA_DEF="-DFHE_FFT_ON_THE_FLY"
[[ "${DMA_STREAM:-0}" == 1 ]] && EXTRA_DEF="$EXTRA_DEF -DFHE_DMA_STREAM"

echo "=== build $TOP (N=$N) ${EXTRA_DEF:+[$EXTRA_DEF]} ==="
[[ -n "${CLEAN:-}" ]] && rm -rf "$OBJ_DIR"
"$VERILATOR" --binary -j "${JOBS:-4}" \
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
  [[ -f "$1" ]] || { echo "ERROR: missing ROM table: $1" >&2; return 1; }
  sed -e 's/memory_initialization_radix.*//I' \
      -e 's/memory_initialization_vector[[:space:]]*=//I' \
      -e 's/[;,]//g' "$1" | grep -viE '[^0-9a-fx[:space:]]' | grep -vE '^[[:space:]]*$' > "$2"
}
coe2mem "$MIF/TwFctrCache_RNSConsts.coe"   "$RUNDIR/fft_rns_rom.mem"
coe2mem "$MIF/FFTStoredTwiddleFactors.coe" "$RUNDIR/fft_all_twiddle_rom.mem"

if [[ "${BUILD_ONLY:-0}" == 1 ]]; then
  echo "RPC executable: $OBJ_DIR/V$TOP"
  echo "RPC working directory: $RUNDIR"
  exit 0
fi

echo "=== running (cwd=$RUNDIR) ==="
PLUSARGS=""
if [[ "$N" == 256 ]]; then
  python3 "$ALOHA_PORT/tvgen/gen_recovery.py" "$WORK"
  PLUSARGS="$PLUSARGS +RECOVERY_DIR=$WORK"
fi
if [[ "$N" == 256 && -n "${LIMBS2:-}" ]]; then
  PLUSARGS="$PLUSARGS +GOLDEN_DIR=$HERE/golden/shared-sram-n256"
fi
[[ -n "${MNIST_DIR:-}" ]] && PLUSARGS="$PLUSARGS +MNIST=$MNIST_DIR"
[[ -n "${LIMBS2:-}" ]] && PLUSARGS="$PLUSARGS +LIMBS2"
[[ "${STREAM_STALLS:-0}" == 1 ]] && PLUSARGS="$PLUSARGS +STREAM_STALLS"
( cd "$RUNDIR" && "$OBJ_DIR/V$TOP" +TVDIR="$WORK" $PLUSARGS ) 2>&1 | tee -a "$LOG"

echo "=== verdict ==="
if grep -qiE "assertion failed|%Error|Failed opening file|TIMEOUT|RESULT: FAIL" "$LOG"; then
  echo "$TOP RESULT: FAIL (see $LOG)"; exit 1
fi
grep -q "$TOP RESULT: PASS" "$LOG" || { echo "$TOP RESULT: FAIL (see $LOG)"; exit 1; }
echo "$TOP RESULT: PASS"
