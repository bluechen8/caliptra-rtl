#!/usr/bin/env bash
# Rung 7: SINGLE-RUN client<->server cosim via DPI-C.
#
#   COSIM_OP=add|mul|rescale ./run_cosim_dpi.sh [golden_dir] [N] [seed]
#
# The whole cosim runs in ONE RTL run: the Aloha RTL (trusted client) keygens +
# encrypts, an in-process Lattigo "server" -- coreAdd/coreMul/coreMulRescale,
# built as a c-shared .so and reached through the DPI shim (fhe_cosim_dpi.cpp) --
# runs the homomorphic eval on the PUBLIC ciphertext mid-simulation, and the RTL
# decrypts. The secret key never leaves the sim process (no re-keygen, no second
# process, no ciphertext files). The SV DPI hooks sit behind +define+FHE_DPI_COSIM,
# so the default Rung 5/6 build never references the DPI symbols.
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
GOLDEN="${GOLDEN:-$ALOHA_PORT/build/cosimdpi$NVAL}"
mkdir -p "$GOLDEN" "$WORK/mif"
GOLDEN_ABS="$(cd "$GOLDEN" && pwd)"

VERILATOR="${VERILATOR:-$(command -v verilator || echo /scratch/boru/chipyard/.conda-env/bin/verilator)}"
TOP=tb_ckks_roundtrip
OBJ_DIR="$SIM_DIR/obj_dir_${TOP}_dpi"
LOG="$SIM_DIR/${TOP}_cosim_dpi.log"
: > "$LOG"

OP="${COSIM_OP:-add}"
case "$OP" in
  add)     CHK="cosim ct+ct";         DESC="ct1+ct2";;
  mul)     CHK="cosim pt*ct ";        DESC="pt(m2)*ct(m1)";;
  rescale) CHK="cosim pt*ct+rescale"; DESC="pt*ct + rescale {q0,q1}->{q0}";;
  *)       echo "unknown COSIM_OP=$OP (add|mul|rescale)"; exit 1;;
esac

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

# ---- build the in-process Lattigo server (.so) -------------------------------
echo "== building libfhecosim.so (cgo c-shared, op-agnostic) ==" | tee -a "$LOG"
mkdir -p "$OBJ_DIR"
SO_DIR="$OBJ_DIR"
( cd "$ALOHA_PORT/tvgen" && source env.sh \
  && CGO_ENABLED=1 go build -tags dpi -buildmode=c-shared -o "$SO_DIR/libfhecosim.so" . ) 2>&1 | tee -a "$LOG"

# ---- build Verilator binary (PWMSk + DPI shim, linked to the .so) ------------
NDEF=(-DFHE_SK_HW -DFHE_DPI_COSIM)
[[ "$NVAL" != 8192 ]] && NDEF+=(-DN_OVERRIDE="$NVAL")
echo "== building $TOP (N=$NVAL, PWMSk + DPI-C) ==" | tee -a "$LOG"
[[ -n "${CLEAN:-}" ]] && rm -rf "$OBJ_DIR"/*.o "$OBJ_DIR"/V"$TOP"*
# Verilator can emit a cosmetic "destroy locked Thread Pool" teardown error
# (nonzero exit) AFTER successfully producing the binary; gate on the binary's
# existence rather than the exit code so pipefail doesn't abort on that glitch.
set +e
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
  "$SIM_DIR/fhe_cosim_dpi.cpp" \
  -LDFLAGS "-L$SO_DIR -lfhecosim -Wl,-rpath,$SO_DIR" \
  2>&1 | tee -a "$LOG"
set -e
[[ -x "$OBJ_DIR/V$TOP" ]] || { echo "$TOP DPI cosim RESULT: FAIL (verilator did not produce V$TOP -- see $LOG)"; exit 1; }

# ---- rundir + ROM .mem -------------------------------------------------------
RUNDIR="$SIM_DIR/.run_${TOP}_cosim_dpi/a/b/c/d"
mkdir -p "$RUNDIR"
coe2mem() {
  [[ -f "$1" ]] || return 0
  sed -e 's/memory_initialization_radix.*//I' \
      -e 's/memory_initialization_vector[[:space:]]*=//I' \
      -e 's/[;,]//g' "$1" | grep -viE '[^0-9a-fx[:space:]]' | grep -vE '^[[:space:]]*$' > "$2"
}
coe2mem "$MIF/TwFctrCache_RNSConsts.coe"   "$RUNDIR/fft_rns_rom.mem"
coe2mem "$MIF/FFTStoredTwiddleFactors.coe" "$RUNDIR/fft_all_twiddle_rom.mem"

# ---- single run: keygen + encrypt + (in-proc server) + decrypt + check -------
echo "== single-run DPI-C cosim (op=$OP): $DESC ==" | tee -a "$LOG"
( cd "$RUNDIR" && "$OBJ_DIR/V$TOP" +DPICOSIM "+DPIOP=$OP" +TVDIR="$GOLDEN_ABS" ) 2>&1 | tee -a "$LOG"

# ---- verdict -----------------------------------------------------------------
echo "== verdict ==" | tee -a "$LOG"
if grep -qiE "assertion failed|%Error: .*\.sv|Failed opening file|TIMEOUT" "$LOG"; then
  echo "$TOP DPI cosim RESULT: FAIL (assertion/error/file-open/timeout -- see $LOG)"; exit 1
fi
if grep -q "RESULT: PASS" "$LOG" && grep -qF "PASS $CHK" "$LOG"; then
  echo "$TOP DPI cosim RESULT: PASS"
else
  echo "$TOP DPI cosim RESULT: FAIL (see $LOG)"; exit 1
fi
