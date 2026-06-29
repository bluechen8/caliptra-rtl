#!/usr/bin/env bash
# Rung 7a: client<->server cosim driver.
#
#   ./run_cosim.sh [golden_dir] [N] [seed]
#
# Proves Aloha-HE ciphertexts interoperate with a standard CKKS library: the
# Aloha RTL (the trusted client) keygens + encrypts two messages m1,m2, an
# untrusted Lattigo "server" homomorphically adds the public ciphertexts
# (ct1+ct2), and the RTL decrypts the result, checking recovered ~= m1+m2.
#
# Single prebuilt PWMSk binary, run twice:
#   phase 1  +ENCRYPT : keygen + encrypt m1,m2 -> dump ct1/ct2 public polys
#   server   go server_add : Lattigo ring.Add  -> sum_{c0,c1}.txt
#   phase 2  +DECRYPT : re-keygen (same seed, sk never on disk) + decrypt sum
#
# Small N regenerates ROM tables (TwFctrCache_RNSConsts / FFTStoredTwiddle) into
# build/N<N>/mif, like run_smalln.sh. N defaults to 8192.
set -euo pipefail

SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALOHA_PORT="$(cd "$SIM_DIR/.." && pwd)"
export ALOHA_PORT
export ALOHA_SRC="${ALOHA_SRC:-$ALOHA_PORT/vendor}"

NVAL=8192
GOLDEN="${1:-}"
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then NVAL="$1"; GOLDEN=""; shift || true
else [[ -n "${1:-}" ]] && shift || true; fi
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then NVAL="$1"; shift; fi
SEED="${1:-1234}"
LOGN=$(python3 -c "import math;print(int(math.log2($NVAL)))")
Q0=0x3ffff7000001          # q0 = 2^46 - 9*2^24 + 1 (TB modulus 0)
Q1=0x7fffff000001          # q1 = 2^47 - 1*2^24 + 1 (TB modulus 1; rescale limb)

WORK="$ALOHA_PORT/build/N$NVAL"
GOLDEN="${GOLDEN:-$ALOHA_PORT/build/cosim$NVAL}"
mkdir -p "$GOLDEN" "$WORK/mif"
GOLDEN_ABS="$(cd "$GOLDEN" && pwd)"

VERILATOR="${VERILATOR:-$(command -v verilator || echo /scratch/boru/chipyard/.conda-env/bin/verilator)}"
TOP=tb_ckks_roundtrip
OBJ_DIR="$SIM_DIR/obj_dir_$TOP"
LOG="$SIM_DIR/${TOP}_cosim.log"
: > "$LOG"

# ---- ROM tables (small N regen; N=8192 uses the shipped MIF) -----------------
if [[ "$NVAL" != 8192 && ( ! -f "$WORK/mif/TwFctrCache_RNSConsts.coe" || -n "${REGEN:-}" ) ]]; then
  echo "== [N=$NVAL] regenerating ROM tables ==" | tee -a "$LOG"
  python3 "$ALOHA_SRC/Scripts/GenerateConstantsROM.py"        "$LOGN" "$WORK/mif/TwFctrCache_RNSConsts.coe"
  python3 "$ALOHA_SRC/Scripts/GenerateStoredFFTTwiddleFct.py" "$LOGN" "$WORK/mif/FFTStoredTwiddleFactors.coe"
fi
MIF="${ALOHA_MIF_DIR:-$([[ "$NVAL" == 8192 ]] && echo "$ALOHA_SRC/Aloha-HE_Common/MemoryInitializationFiles" || echo "$WORK/mif")}"

# ---- inputs m1, m2 -----------------------------------------------------------
echo "== generating plaintexts m1,m2 (seed=$SEED) ==" | tee -a "$LOG"
python3 "$ALOHA_PORT/tvgen/gen_cosim.py" "$LOGN" "$GOLDEN_ABS" "$SEED" | tee -a "$LOG"

# ---- build (PWMSk / SCHEME=1) ------------------------------------------------
NDEF=(-DFHE_SK_HW)
[[ "$NVAL" != 8192 ]] && NDEF+=(-DN_OVERRIDE="$NVAL")
echo "== building $TOP (N=$NVAL, PWMSk) ==" | tee -a "$LOG"
[[ -n "${CLEAN:-}" ]] && rm -rf "$OBJ_DIR"
"$VERILATOR" --binary -j 0 \
  --timing --assert \
  --top-module "$TOP" \
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
  -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-SELRANGE \
  -Wno-LATCH -Wno-IMPLICIT -Wno-UNSIGNED -Wno-CMPCONST -Wno-ASCRANGE \
  -Wno-PINMISSING -Wno-WIDTHCONCAT -Wno-GENUNNAMED \
  --Mdir "$OBJ_DIR" \
  "${NDEF[@]}" \
  -f "$SIM_DIR/${TOP}.f" \
  2>&1 | tee -a "$LOG"

# ---- rundir + ROM .mem -------------------------------------------------------
RUNDIR="$SIM_DIR/.run_${TOP}_cosim/a/b/c/d"
mkdir -p "$RUNDIR"
coe2mem() {
  [[ -f "$1" ]] || return 0
  sed -e 's/memory_initialization_radix.*//I' \
      -e 's/memory_initialization_vector[[:space:]]*=//I' \
      -e 's/[;,]//g' "$1" | grep -viE '[^0-9a-fx[:space:]]' | grep -vE '^[[:space:]]*$' > "$2"
}
coe2mem "$MIF/TwFctrCache_RNSConsts.coe"   "$RUNDIR/fft_rns_rom.mem"
coe2mem "$MIF/FFTStoredTwiddleFactors.coe" "$RUNDIR/fft_all_twiddle_rom.mem"

# COSIM_OP selects the homomorphic op the server runs:
#   add (default) -> ct1+ct2 (Rung 7a),  mul -> pt(m2)*ct(m1) (Rung 7b)
OP="${COSIM_OP:-add}"
case "$OP" in
  add)     P1=+ENCRYPT; P2=+DECRYPT; SVC=server_add;         CHK="PASS cosim ct+ct";          DESC="ct1+ct2";;
  mul)     P1=+PMULENC; P2=+PMULDEC; SVC=server_mul;         CHK="PASS cosim pt*ct";          DESC="pt(m2)*ct(m1)";;
  rescale) P1=+RESCENC; P2=+RESCDEC; SVC=server_mul_rescale; CHK="PASS cosim pt*ct+rescale";  DESC="pt*ct + rescale {q0,q1}->{q0}";;
  *)       echo "unknown COSIM_OP=$OP (add|mul|rescale)"; exit 1;;
esac

# ---- phase 1: encrypt --------------------------------------------------------
echo "== phase 1: $P1 (op=$OP) ==" | tee -a "$LOG"
( cd "$RUNDIR" && "$OBJ_DIR/V$TOP" "$P1" +TVDIR="$GOLDEN_ABS" ${I2FSCALE:+ +I2FSCALE=$I2FSCALE} ) 2>&1 | tee -a "$LOG"
grep -q "RESULT: PASS" "$LOG" || { echo "cosim RESULT: FAIL (phase 1 -- see $LOG)"; exit 1; }

# ---- keygen NTT cross-check (independent of the round-trip) -------------------
echo "== keygen NTT cross-check ==" | tee -a "$LOG"
( cd "$ALOHA_PORT/tvgen" && source env.sh && python3 check_keygen.py "$GOLDEN_ABS" ) 2>&1 | tee -a "$LOG"
grep -q "keygen NTT cross-check: 0/" "$LOG" \
  || { echo "cosim RESULT: FAIL (keygen NTT cross-check -- see $LOG)"; exit 1; }

# ---- untrusted server: Lattigo -----------------------------------------------
echo "== server: Lattigo $DESC ($SVC) ==" | tee -a "$LOG"
if [[ "$OP" == rescale ]]; then
  ( cd "$ALOHA_PORT/tvgen" && source env.sh && go run . "$SVC" "$LOGN" "$Q0" "$Q1" "$GOLDEN_ABS" ) 2>&1 | tee -a "$LOG"
else
  ( cd "$ALOHA_PORT/tvgen" && source env.sh && go run . "$SVC" "$LOGN" "$Q0" "$GOLDEN_ABS" ) 2>&1 | tee -a "$LOG"
fi

# ---- phase 2: decrypt + check ------------------------------------------------
echo "== phase 2: $P2 (decrypt server result, check) ==" | tee -a "$LOG"
( cd "$RUNDIR" && "$OBJ_DIR/V$TOP" "$P2" +TVDIR="$GOLDEN_ABS" ${I2FSCALE:+ +I2FSCALE=$I2FSCALE} ) 2>&1 | tee -a "$LOG"

# ---- verdict -----------------------------------------------------------------
echo "== verdict ==" | tee -a "$LOG"
if grep -qiE "assertion failed|%Error|Failed opening file|TIMEOUT" "$LOG"; then
  echo "$TOP cosim RESULT: FAIL (assertion/error/file-open/timeout -- see $LOG)"; exit 1
fi
# need BOTH phases' PASS and the phase-2 recovered check
if [[ $(grep -c "RESULT: PASS" "$LOG") -ge 2 ]] && grep -qF "$CHK" "$LOG"; then
  echo "$TOP cosim RESULT: PASS"
else
  echo "$TOP cosim RESULT: FAIL (see $LOG)"; exit 1
fi
