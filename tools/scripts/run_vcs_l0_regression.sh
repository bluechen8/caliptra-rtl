#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# VCS L0 regression runner — the VCS counterpart of run_verilator_l0_regression.py.
#
# Why: the full caliptra_top_tb needs a Verilator new enough for SystemVerilog
# `process::self()` + IEEE force/release (upstream pins v5.044); the Verilator we
# have (5.022) can't build it. VCS can. This runner mirrors the Python flow under
# VCS: build simv.caliptra_top_tb ONCE, then run every test in L0_regression.yml
# in a bounded parallel pool from its own rundir (reusing the shared simv), and
# grep "* TESTCASE PASSED".
#
# It also supports the FHE-enabled build (Aloha core + FHE_WALKER compiled in), so
# we can confirm the FHE integration doesn't regress the existing L0 suite:
#
#   ./run_vcs_l0_regression.sh                 # default build, full L0 list
#   BUILD=fhe ./run_vcs_l0_regression.sh       # ABR+FHE build, full L0 list
#   BUILD=fhe_noabr ./run_vcs_l0_regression.sh # NoABR+FHE (tape-out anchor):
#                                              #   curated fhe_noabr_regression.yml
#                                              #   (ABR/ML-DSA/ML-KEM dropped, FHE added)
#   BUILD=fhe JOBS=8 ./run_vcs_l0_regression.sh smoke_test_kv smoke_test_sha256   # subset
#
# Env: BUILD=default|fhe|fhe_noabr (default default) · JOBS=<n> parallel sims (default 6) ·
#      FHE_N=<n> for the FHE build (default 256) · TIMEOUT=<sec> per sim (default 3600).
set -o pipefail   # NOT -u: vlsi.bashrc / caliptra-env.sh reference unbound vars

BUILD="${BUILD:-default}"
JOBS="${JOBS:-6}"
FHE_N="${FHE_N:-256}"
TIMEOUT="${TIMEOUT:-3600}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"        # tools/scripts
VSRC="$(cd "$HERE/../../.." && pwd)"                        # vsrc (holds caliptra-env.sh)

# --- toolchains: VCS + rv32 firmware gcc (source under set +u) ---
source /ecad/tools/vlsi.bashrc
# caliptra-env.sh sets CALIPTRA_ROOT=$(pwd)/caliptra, so source it from vsrc.
pushd "$VSRC" >/dev/null; source ./caliptra-env.sh; popd >/dev/null
export CALIPTRA_WORKSPACE="$(dirname "$CALIPTRA_ROOT")"
export GCC_PREFIX="${CALIPTRA_GCC_PREFIX:-riscv64-unknown-elf}"

MK="$CALIPTRA_ROOT/tools/scripts/Makefile"
STIM="$CALIPTRA_ROOT/src/integration/stimulus/L0_regression.yml"
TEST_GEN_FILES=(
  "$CALIPTRA_ROOT/src/ecc/tb/ecc_secp384r1.exe"
  "$CALIPTRA_ROOT/src/doe/tb/doe_test_gen.py"
  "$CALIPTRA_ROOT/src/sha256/tb/sha256_wntz_test_gen.py"
  "$CALIPTRA_ROOT/submodules/adams-bridge/src/abr_top/uvmf/Dilithium_ref/dilithium/ref/test/test_dilithium5"
  "$CALIPTRA_ROOT/submodules/adams-bridge/src/abr_top/uvmf/Dilithium_ref/dilithium/ref/test/test_dilithium5_debug"
)

SCRATCH="$CALIPTRA_ROOT/vcs_regr_${BUILD}"
COMMON="$SCRATCH/.simv_build"

# --- per-build make flags + sim run args ---
# BUILD modes: default | fhe (ABR+FHE) | fhe_noabr (NoABR+FHE -- the tape-out
# anchor; uses the curated fhe_noabr_regression.yml which drops ABR/ML-DSA/ML-KEM
# tests and adds the FHE accelerator tests, incl. the KeyVault-seed smoke).
MK_ARGS=(CALIPTRA_ROOT="$CALIPTRA_ROOT")
RUN_ARGS=(+CLP_REGRESSION)
IS_FHE=0
if [[ "$BUILD" == "fhe" || "$BUILD" == "fhe_noabr" ]]; then
  IS_FHE=1
  export ALOHA_PORT="$CALIPTRA_ROOT/src/fhe/aloha"
  export ALOHA_SRC="$ALOHA_PORT/vendor"
  DEFS="+define+FHE_WALKER +define+FHE_N=${FHE_N}"
  if [[ "$BUILD" == "fhe_noabr" ]]; then
    # NoABR = the tape-out anchor.
    DEFS="$DEFS +define+CALIPTRA_NO_ADAMS_BRIDGE"
    STIM="$CALIPTRA_ROOT/src/integration/stimulus/fhe_noabr_regression.yml"
  fi
  MK_ARGS+=(TB_VF="$CALIPTRA_ROOT/src/integration/config/caliptra_top_tb_fhe.vf"
            EXTRA_DEFS="$DEFS")
  RUN_ARGS+=(+FHE_TVDIR=.)
fi

# --- test list (positional args override; else parse L0_regression.yml) ---
if [[ $# -gt 0 ]]; then
  TESTS=("$@")
else
  mapfile -t TESTS < <(grep -oE '\.\./test_suites/[A-Za-z0-9_]+/' "$STIM" \
                       | sed 's#\.\./test_suites/##; s#/##' | sort -u)
fi
echo "== VCS L0 regression: BUILD=$BUILD, ${#TESTS[@]} tests, JOBS=$JOBS =="

coe2mem() {
  [[ -f "$1" ]] || return 0
  sed -e 's/memory_initialization_radix.*//I' \
      -e 's/memory_initialization_vector[[:space:]]*=//I' \
      -e 's/[;,]//g' "$1" | grep -viE '[^0-9a-fx[:space:]]' | grep -vE '^[[:space:]]*$' > "$2"
}

# --- build simv ONCE ---
rm -rf "$SCRATCH"; mkdir -p "$COMMON"
echo "== [1/2] building simv.caliptra_top_tb ($BUILD) =="
make -C "$COMMON" -f "$MK" "${MK_ARGS[@]}" TESTNAME=iccm_lock vcs-build > "$COMMON/build.log" 2>&1
if [[ ! -x "$COMMON/simv.caliptra_top_tb" ]]; then
  echo "FATAL: simv build failed — see $COMMON/build.log"; tail -25 "$COMMON/build.log"; exit 1
fi
echo "   simv built."

# FHE build: pre-generate the Aloha ROM .mem + a golden input.txt ONCE (the idle
# FHE core $readmemh's them; identical for every test at this N).
FHE_TV="$SCRATCH/.fhe_tv"
if [[ "$IS_FHE" == 1 ]]; then
  mkdir -p "$FHE_TV/mif"
  LOGN=$(python3 -c "import math;print(int(math.log2($FHE_N)))")
  python3 "$ALOHA_PORT/tvgen/gen_roundtrip.py" "$LOGN" "$FHE_TV" >/dev/null 2>&1
  python3 "$ALOHA_PORT/vendor/Scripts/GenerateConstantsROM.py"        "$LOGN" "$FHE_TV/mif/rns.coe" >/dev/null 2>&1
  python3 "$ALOHA_PORT/vendor/Scripts/GenerateStoredFFTTwiddleFct.py" "$LOGN" "$FHE_TV/mif/tw.coe"  >/dev/null 2>&1
  coe2mem "$FHE_TV/mif/rns.coe" "$FHE_TV/fft_rns_rom.mem"
  coe2mem "$FHE_TV/mif/tw.coe"  "$FHE_TV/fft_all_twiddle_rom.mem"
fi

# --- one test: build firmware, stage aux files, run the shared simv from its rundir ---
run_one() {
  local t="$1" rd="$SCRATCH/$1"
  mkdir -p "$rd"
  # firmware -> program.hex / iccm.hex / dccm.hex / mailbox.hex
  if ! make -C "$rd" -f "$MK" CALIPTRA_ROOT="$CALIPTRA_ROOT" TESTNAME="$t" program.hex \
        > "$rd/fw.log" 2>&1 || [[ ! -f "$rd/program.hex" ]]; then
    echo "FAIL" > "$rd/STATUS"; return
  fi
  cp "${TEST_GEN_FILES[@]}" "$rd/" 2>/dev/null
  [[ "$IS_FHE" == 1 ]] && cp "$FHE_TV/input.txt" "$FHE_TV"/*.mem "$rd/" 2>/dev/null
  # run the shared simv from the test's rundir (simv finds its .so via $ORIGIN,
  # reads program.hex + test vectors from cwd)
  ( cd "$rd" && timeout "$TIMEOUT" "$COMMON/simv.caliptra_top_tb" "${RUN_ARGS[@]}" ) \
      > "$rd/run.log" 2>&1
  # PASS = firmware TESTCASE PASSED AND no FHE-specific TB failure. The FHE
  # round-trip / KeyVault-seed checks live in the TB (independent of the firmware
  # STDOUT pass code), so a bad ct or a KV-seed mismatch would otherwise slip
  # past the TESTCASE-PASSED grep. Those FAIL markers only appear in FHE tests.
  if grep -q '\* TESTCASE PASSED' "$rd/run.log" \
     && ! grep -qE '\[FHE-DRAM\] FHE DMA round-trip: FAIL|\[FHE-KV-TB\] FAIL' "$rd/run.log"; then
    echo "PASS" > "$rd/STATUS"
  else echo "FAIL" > "$rd/STATUS"; fi
}

# --- bounded parallel pool ---
echo "== [2/2] running ${#TESTS[@]} tests (<=$JOBS parallel) =="
running=0
for t in "${TESTS[@]}"; do
  run_one "$t" &
  running=$((running+1))
  if (( running >= JOBS )); then wait -n; running=$((running-1)); fi
done
wait

# --- summary ---
echo ""; echo "======================= SUMMARY ($BUILD) ======================="
pass=0; fail=0; failed=()
for t in "${TESTS[@]}"; do
  s=$(cat "$SCRATCH/$t/STATUS" 2>/dev/null || echo "FAIL")
  if [[ "$s" == "PASS" ]]; then pass=$((pass+1)); else fail=$((fail+1)); failed+=("$t"); fi
done
echo "PASS: $pass / ${#TESTS[@]}"
if (( fail > 0 )); then
  echo "FAIL: $fail  -> ${failed[*]}"
  echo "(logs: $SCRATCH/<test>/run.log · fw.log)"
  exit 1
fi
echo "All L0 tests passed on the $BUILD build."
