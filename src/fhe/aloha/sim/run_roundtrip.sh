#!/usr/bin/env bash
# Rung 5/6: build + run the composed-core CKKS round-trip TB.
#
#   ROUNDTRIP=1 ./run_roundtrip.sh <golden_dir> [N] [extra verilator args...]   # Rung 5c
#   SKSCHEME_HW=1 ./run_roundtrip.sh <golden_dir> [N] [extra args...]           # Rung 6
#
# The TB requires a run-mode plusarg (this script sets +ROUNDTRIP when ROUNDTRIP
# is in the env, +SKHW when SKSCHEME_HW is). <golden_dir> holds the $readmemh
# goldens (input.txt + pk1_seeds.txt [+ error_seed.txt]); make it with
# tvgen/gen_roundtrip.py <LOGN> <dir>. N defaults to 8192; for small N pass it +
# the matching ROM dir via ALOHA_MIF_DIR.
#
# (The old Rung-5a SEAL-ciphertext cross-check was retired at the C'-2 PRNG swap
# -- the RTL sampler no longer reproduces SEAL's a/e; see tb_ckks_roundtrip.sv.)
#
# Mirrors run_tb.sh: depth-5 rundir + .coe->.mem ROM init, but forwards the
# golden dir to the binary via +TVDIR and (optionally) overrides N.
set -euo pipefail

GOLDEN="${1:?usage: run_roundtrip.sh <golden_dir> [N] [extra args...]}"
shift || true
NVAL=8192
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then NVAL="$1"; shift; fi
EXTRA_ARGS=("$@")

SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ALOHA_PORT="$(cd "$SIM_DIR/.." && pwd)"
export ALOHA_SRC="${ALOHA_SRC:-$ALOHA_PORT/vendor}"
VERILATOR="${VERILATOR:-$(command -v verilator || echo /scratch/boru/chipyard/.conda-env/bin/verilator)}"

GOLDEN_ABS="$(cd "$GOLDEN" && pwd)"
TOP=tb_ckks_roundtrip
OBJ_DIR="$SIM_DIR/obj_dir_$TOP"
LOG="$SIM_DIR/${TOP}.log"

NDEF=()
[[ "$NVAL" != 8192 ]] && NDEF=(-DN_OVERRIDE="$NVAL")
# Rung 6c: SKSCHEME_HW elaborates the dedicated secret-key PWM (PWMSk).
[[ -n "${SKSCHEME_HW:-}" ]] && NDEF+=(-DFHE_SK_HW)
# Stage-B' 2b: WALKER drives the real core via the fhe_microseq FSM (needs PWMSk).
[[ -n "${WALKER:-}" ]] && NDEF+=(-DFHE_SK_HW)

echo "=== $TOP (N=$NVAL, goldens=$GOLDEN_ABS) ==="
[[ -n "${CLEAN:-}" ]] && rm -rf "$OBJ_DIR"

"$VERILATOR" --binary -j 0 \
  --timing --assert \
  --top-module "$TOP" \
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
  -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-SELRANGE \
  -Wno-LATCH -Wno-IMPLICIT -Wno-UNSIGNED -Wno-CMPCONST -Wno-ASCRANGE \
  -Wno-PINMISSING -Wno-WIDTHCONCAT -Wno-GENUNNAMED \
  --Mdir "$OBJ_DIR" \
  "${NDEF[@]}" "${EXTRA_ARGS[@]}" \
  -f "$SIM_DIR/${TOP}.f" \
  2>&1 | tee "$LOG"

RUNDIR="$SIM_DIR/.run_$TOP/a/b/c/d"
mkdir -p "$RUNDIR"

MIF="${ALOHA_MIF_DIR:-$ALOHA_SRC/Aloha-HE_Common/MemoryInitializationFiles}"
coe2mem() {
  [[ -f "$1" ]] || return 0
  sed -e 's/memory_initialization_radix.*//I' \
      -e 's/memory_initialization_vector[[:space:]]*=//I' \
      -e 's/[;,]//g' "$1" | grep -viE '[^0-9a-fx[:space:]]' | grep -vE '^[[:space:]]*$' > "$2"
}
coe2mem "$MIF/TwFctrCache_RNSConsts.coe"   "$RUNDIR/fft_rns_rom.mem"
coe2mem "$MIF/FFTStoredTwiddleFactors.coe" "$RUNDIR/fft_all_twiddle_rom.mem"

PLUSARGS=(+TVDIR="$GOLDEN_ABS")
[[ -n "${ROUNDTRIP:-}" ]] && PLUSARGS+=(+ROUNDTRIP)
[[ -n "${IDENTITY:-}" ]] && PLUSARGS+=(+IDENTITY)
[[ -n "${SKSCHEME_HW:-}" ]] && PLUSARGS+=(+SKHW)
[[ -n "${WALKER:-}" ]] && PLUSARGS+=(+WALKER)

echo "=== running (cwd=$RUNDIR) ==="
( cd "$RUNDIR" && "$OBJ_DIR/V$TOP" "${PLUSARGS[@]}" ) 2>&1 | tee -a "$LOG"

echo "=== verdict ==="
if grep -qiE "assertion failed|%Error|Failed opening file|TIMEOUT" "$LOG"; then
  echo "$TOP RESULT: FAIL (assertion/error/file-open/timeout -- see $LOG)"; exit 1
fi
grep -q "RESULT: PASS" "$LOG" || { echo "$TOP RESULT: FAIL (see $LOG)"; exit 1; }

# Rung 6: independent NTT-oracle cross-check that the HW-derived s_ntt is the
# genuine forward-NTT of the sampled ternary s (the round-trip alone can't catch
# a garbage key -- encrypt-negate and decrypt MontMuls cancel for any key blob).
if [[ -n "${SKSCHEME_HW:-}" && -f "$GOLDEN_ABS/hw_s_tern.txt" ]]; then
  echo "=== keygen NTT cross-check ==="
  TVGEN="$ALOHA_PORT/tvgen"
  ( cd "$TVGEN" && source env.sh && python3 check_keygen.py "$GOLDEN_ABS" ) 2>&1 | tee -a "$LOG"
  grep -q "keygen NTT cross-check: 0/" "$LOG" \
    || { echo "$TOP RESULT: FAIL (keygen NTT cross-check -- see $LOG)"; exit 1; }
fi

echo "$TOP RESULT: PASS"
