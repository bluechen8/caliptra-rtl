#!/usr/bin/env bash
# Build + run the fhe_top unit TB (register map v2).
#
#   ./run_fhe_top_dma_tb.sh [LOGN]      # default LOGN=8 (N=256)
#
# fhe_top is built with +define+FHE_WALKER. Every segment moves through
# Caliptra's axi_dma and an AXI memory over the TB memory, the ENCRYPT message
# and DECRYPT slots through Caliptra's AES-GCM. The TB plays firmware and host:
# KeyVault seed read, CONFIG and slot bases, commands, GCM setup, tag checks
# and sealing. It checks round trips, recovery, refresh, the single-seed
# stream, command preconditions, the commit barrier, lease, address, error and
# abort cases. Options: FHE_L=<1..15> (largest level, default 2), LIMBS2=1
# (two-limb ciphertexts and the N=256 key golden), STREAM_STALLS=1, MNIST_DIR=<dir>,
# RECOVER=0 (production build without the RECOVER command: checks it is refused
# and runs the level sweep by round trip only). +RPC turns the binary into the
# emulator's Aloha RTL link (BUILD_ONLY=1 prints its path); BUILD_ONLY builds
# default to RECOVER=0, like silicon.
#
# Expect: "fhe_top_dma_tb RESULT: PASS".
set -euo pipefail

LOGN="${1:-8}"
N=$((1 << LOGN))
FHE_L="${FHE_L:-2}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # src/fhe/tb
FHE="$(dirname "$HERE")"                                  # src/fhe
export ALOHA_PORT="$FHE/aloha"
export ALOHA_SRC="${ALOHA_SRC:-$ALOHA_PORT/vendor}"
export CALIPTRA_ROOT="$(cd "$FHE/../.." && pwd)"          # caliptra repo root
export CALIPTRA_PRIM_ROOT="${CALIPTRA_PRIM_ROOT:-$CALIPTRA_ROOT/src/caliptra_prim_generic}"
export CALIPTRA_PRIM_MODULE_PREFIX="${CALIPTRA_PRIM_MODULE_PREFIX:-caliptra_prim_generic}"
VERILATOR="${VERILATOR:-$(command -v verilator || echo /scratch/boru/chipyard/.conda-env/bin/verilator)}"

TOP=fhe_top_dma_tb
FLIST="$HERE/${TOP}.f"
# All build/run artifacts go under src/fhe/build/ (gitignored) -- never under tb/.
BUILD="$FHE/build"
WORK="$BUILD/dmaN${N}L${FHE_L}"
MIF="$WORK/mif"
OBJ_DIR="${OBJ_DIR:-$BUILD/obj_dir_$TOP}"
LOG="${LOG:-$BUILD/${TOP}.log}"
mkdir -p "$MIF"

echo "== [N=$N / LOGN=$LOGN / L=$FHE_L] regenerating the CROM table + plaintext =="
# Generate the CROM locally for every N and L; never use a checked-in table.
python3 "$ALOHA_PORT/vendor/Scripts/GenerateConstantsROM.py"        "$LOGN" "$MIF/TwFctrCache_RNSConsts.coe" --profiles "$FHE_L"

python3 "$ALOHA_PORT/tvgen/gen_roundtrip.py" "$LOGN" "$WORK" >/dev/null

# RECOVER (plaintext-equivalent output) exists only in verification builds.
RECOVER="${RECOVER:-$([[ "${BUILD_ONLY:-0}" == 1 ]] && echo 0 || echo 1)}"
RECOVER_DEF="-DFHE_RECOVER_CMD"
[[ "$RECOVER" == 0 ]] && RECOVER_DEF=""
echo "=== build $TOP (N=$N) ${RECOVER_DEF:-[production: no RECOVER]} ==="
[[ -n "${CLEAN:-}" ]] && rm -rf "$OBJ_DIR"
"$VERILATOR" --binary -j "${JOBS:-4}" \
  --timing --assert \
  --top-module "$TOP" \
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
  -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-SELRANGE \
  -Wno-LATCH -Wno-IMPLICIT -Wno-UNSIGNED -Wno-CMPCONST -Wno-ASCRANGE \
  -Wno-PINMISSING -Wno-WIDTHCONCAT -Wno-GENUNNAMED -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
  -DFHE_WALKER -DFHE_N="$N" -DFHE_L="$FHE_L" $RECOVER_DEF \
  --Mdir "$OBJ_DIR" \
  -f "$FLIST" \
  -o "V$TOP" \
  2>&1 | tee "$LOG"

# Rundir (depth-5, under build/) with the CROM table the TB copies in, as firmware does.
RUNDIR="${RUNDIR:-$BUILD/.run_$TOP/a/b/c/d}"
mkdir -p "$RUNDIR"
coe2mem() {
  [[ -f "$1" ]] || { echo "ERROR: missing ROM table: $1" >&2; return 1; }
  sed -e 's/memory_initialization_radix.*//I' \
      -e 's/memory_initialization_vector[[:space:]]*=//I' \
      -e 's/[;,]//g' "$1" | grep -viE '[^0-9a-fx[:space:]]' | grep -vE '^[[:space:]]*$' > "$2"
}
coe2mem "$MIF/TwFctrCache_RNSConsts.coe"   "$RUNDIR/fft_rns_rom.mem"

if [[ "${BUILD_ONLY:-0}" == 1 ]]; then
  echo "RPC executable: $OBJ_DIR/V$TOP"
  echo "RPC working directory: $RUNDIR"
  exit 0
fi

echo "=== running (cwd=$RUNDIR) ==="
PLUSARGS=""
if [[ "$N" == 256 && "$RECOVER" == 1 ]]; then
  python3 "$ALOHA_PORT/tvgen/gen_recovery.py" "$WORK"
  PLUSARGS="$PLUSARGS +RECOVERY_DIR=$WORK"
fi
if [[ "$N" == 256 && -n "${LIMBS2:-}" ]]; then
  PLUSARGS="$PLUSARGS +GOLDEN_DIR=$HERE/golden/shared-sram-n256"
fi
[[ -n "${MNIST_DIR:-}" ]] && PLUSARGS="$PLUSARGS +MNIST=$MNIST_DIR"
[[ -n "${LIMBS2:-}" ]] && PLUSARGS="$PLUSARGS +LIMBS2"
[[ "${STREAM_STALLS:-0}" == 1 ]] && PLUSARGS="$PLUSARGS +STREAM_STALLS"
[[ "${QUICK:-0}" == 1 ]] && PLUSARGS="$PLUSARGS +QUICK"
( cd "$RUNDIR" && "$OBJ_DIR/V$TOP" +TVDIR="$WORK" $PLUSARGS ) 2>&1 | tee -a "$LOG"

echo "=== verdict ==="
if grep -qiE "assertion failed|%Error|Failed opening file|TIMEOUT|RESULT: FAIL" "$LOG"; then
  echo "$TOP RESULT: FAIL (see $LOG)"; exit 1
fi
grep -q "$TOP RESULT: PASS" "$LOG" || { echo "$TOP RESULT: FAIL (see $LOG)"; exit 1; }
echo "$TOP RESULT: PASS"
