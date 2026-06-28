#!/usr/bin/env bash
# Reproduce the full Aloha-HE engine test set at ring dimension N = 2^LOGN.
# Regenerates the ROM tables + golden vectors for N, then runs every engine
# testbench and prints a PASS/FAIL summary. All artifacts go under build/N<N>/
# (gitignored). Run from src/fhe/aloha (the script cd's there itself).
#
#   ./run_smalln.sh [LOGN]     # default LOGN=8 (N=256). Smallest all-green: LOGN=7 (N=128);
#                              # below that the on-the-fly twiddle cache (UnifiedTwFctGen) breaks
#                              # for NTT + on-the-fly FFT (stored-FFT / pointwise engines still pass).
#
# At LOGN=13 (N=8192) this reproduces the shipped vectors; for a quick smoke against
# the shipped tv directly (no regeneration) see README section A.1.
set -uo pipefail
cd "$(dirname "$0")"                                   # src/fhe/aloha
LOGN="${1:-8}"; N=$((1 << LOGN))
SHIP="$PWD/vendor/Aloha-HE_Common/Testbench/tv"
WORK="$PWD/build/N$N"; MIF="$WORK/mif"; TV="$WORK/tv"; SIM="$PWD/sim"
mkdir -p "$MIF" "$TV"

echo "== [N=$N / LOGN=$LOGN] regenerating ROM tables + golden vectors =="
python3 vendor/Scripts/GenerateConstantsROM.py        "$LOGN" "$MIF/TwFctrCache_RNSConsts.coe"
python3 vendor/Scripts/GenerateStoredFFTTwiddleFct.py "$LOGN" "$MIF/FFTStoredTwiddleFactors.coe"
( cd tvgen && source env.sh && go build -o "$WORK/tvgen" . && "$WORK/tvgen" gen "$LOGN" "$TV" ) >/dev/null  # NTT (Lattigo)
python3 tvgen/gen_fft.py      gen "$LOGN" "$TV"         >/dev/null   # FFT (numpy)
python3 tvgen/gen_sampling.py     "$LOGN" "$SHIP" "$TV" >/dev/null   # sampling (Trivium)
python3 tvgen/gen_pointwise.py gen "$LOGN" "$SHIP" "$TV" >/dev/null   # IntToFlp + PWM (real oracles)
python3 tvgen/gen_rns.py       gen "$LOGN" "$SHIP" "$TV" >/dev/null   # RNS message + e1/v (real oracle)

pass=0; fail=0
# run <label> <use_smallN: y|n> <TOP> <flist> [extra -G args...]
run() {
  local label=$1 sn=$2 top=$3 flist=$4; shift 4
  local log="$WORK/$label.log"
  for attempt in 1 2 3; do                              # retry the verilator -j0 transient
    if [ "$sn" = y ]; then
      CLEAN=1 ALOHA_MIF_DIR="$MIF" ALOHA_TV_DIR="$TV" "$SIM/run_tb.sh" "$top" "$flist" "$@" -GN=$N >"$log" 2>&1
    else
      CLEAN=1 "$SIM/run_tb.sh" "$top" "$flist" "$@" >"$log" 2>&1
    fi
    grep -q "destroy locked Thread Pool" "$log" || break
  done
  if grep -q "RESULT: PASS" "$log"; then echo "  PASS  $label"; pass=$((pass + 1))
  else echo "  FAIL  $label  (see $log)"; fail=$((fail + 1)); fi
}

echo "== [N=$N] running engines =="
run ModMul         n tb_ModMul                aloha_rung1.f
run FFTButterfly   n tb_FFTButterfly          tb_fftbutterfly.f
run IntToFlp       y tb_IntToFlpWrapper       tb_inttoflp.f
run RandomSampling y tb_RandomSampling        tb_randomsampling.f
run PWM            y tb_PWM                   tb_pwm.f
run RNS            y tb_RNS                   tb_rns.f
run NTT            y tb_UnifiedTransformation tb_unifiedtransformation.f -GDO_FFT=0 -GFORWARD_TRANSFORM=1
run FFT_stored     y tb_UnifiedTransformation tb_unifiedtransformation.f -GDO_FFT=1 -GON_THE_FLY_GENERATION=0 -GFORWARD_TRANSFORM=1
run FFT_onthefly   y tb_UnifiedTransformation tb_unifiedtransformation.f -GDO_FFT=1 -GON_THE_FLY_GENERATION=1 -GFORWARD_TRANSFORM=1

echo "== [N=$N] $pass passed, $fail failed =="
exit $((fail > 0))
