#!/usr/bin/env bash
# Generic Aloha-HE bring-up TB runner (Rungs 2+).
#
#   ./run_tb.sh <TOP_MODULE> <filelist.f>
#
# Builds + runs an unmodified Aloha-HE testbench in standalone Verilator against
# the vendored RTL (aloha/vendor) plus our technology-generic ports (aloha/rtl).
# Self-checking TBs end at $finish; PASS = reached $finish with 0 assertion
# failures and no file-open errors.
#
# The vendored TBs read golden vectors via a hardcoded relative path
# "../../../../../testvectors/<file>". We satisfy that WITHOUT editing the TBs:
# run the binary from a cwd nested exactly 5 levels under this sim dir, and drop
# a `testvectors` symlink at this sim dir pointing at vendor/.../Testbench/tv.
#
# Env: ALOHA_SRC (default ../vendor), VERILATOR (default chipyard conda).
set -euo pipefail

TOP="${1:?usage: run_tb.sh <TOP_MODULE> <filelist.f> [extra verilator args...]}"
FLIST="${2:?usage: run_tb.sh <TOP_MODULE> <filelist.f> [extra verilator args...]}"
shift 2 || true
EXTRA_ARGS=("$@")   # e.g. -GDO_FFT=0 -GFORWARD_TRANSFORM=1

SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ALOHA_PORT="$(cd "$SIM_DIR/.." && pwd)"
export ALOHA_SRC="${ALOHA_SRC:-$ALOHA_PORT/vendor}"
# Prefer verilator on PATH; fall back to the chipyard conda build. Override with VERILATOR=.
VERILATOR="${VERILATOR:-$(command -v verilator || echo /scratch/boru/chipyard/.conda-env/bin/verilator)}"

[[ -f "$FLIST" ]] || FLIST="$SIM_DIR/$FLIST"
TV_DIR="${ALOHA_TV_DIR:-$ALOHA_SRC/Aloha-HE_Common/Testbench/tv}"
OBJ_DIR="$SIM_DIR/obj_dir_$TOP"
LOG="$SIM_DIR/${TOP}.log"

[[ -d "$TV_DIR" ]] || { echo "ERROR: testvector dir not found: $TV_DIR" >&2; exit 2; }

echo "=== $TOP ==="
echo "ALOHA_SRC = $ALOHA_SRC"
# Incremental by default: Verilator re-elaborates each run and its generated
# make rebuilds only changed sources. Force a clean rebuild with CLEAN=1.
[[ -n "${CLEAN:-}" ]] && rm -rf "$OBJ_DIR"

"$VERILATOR" --binary -j 0 \
  --timing --assert \
  --top-module "$TOP" \
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
  -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-SELRANGE \
  -Wno-LATCH -Wno-IMPLICIT -Wno-UNSIGNED -Wno-CMPCONST -Wno-ASCRANGE \
  -Wno-PINMISSING -Wno-WIDTHCONCAT -Wno-GENUNNAMED \
  --Mdir "$OBJ_DIR" \
  "${EXTRA_ARGS[@]}" \
  -f "$FLIST" \
  2>&1 | tee "$LOG"

# Set up a depth-5 rundir + testvectors symlink so the TB's hardcoded
# ../../../../../testvectors/ path resolves to the vendored tv/ dir.
RUNDIR="$SIM_DIR/.run_$TOP/a/b/c/d"   # 5 levels under SIM_DIR (.run_*,a,b,c,d)
mkdir -p "$RUNDIR"
ln -sfn "$TV_DIR" "$SIM_DIR/testvectors"

# Convert the upstream .coe ROM-init files to $readmemh hex (one word/line) in
# the run cwd, so the aloha_rom_sp INIT_FILE names resolve. (.coe = a radix
# line + a vector line + one hex/line, terminated by ';'.)
MIF="${ALOHA_MIF_DIR:-$ALOHA_SRC/Aloha-HE_Common/MemoryInitializationFiles}"
coe2mem() {  # <src.coe> <dst.mem>
  [[ -f "$1" ]] || return 0
  # Always regenerate: the mtime skip is unsafe across ALOHA_MIF_DIR switches
  # (a stale small-N .mem could shadow a default-N source, or vice versa).
  sed -e 's/memory_initialization_radix.*//I' \
      -e 's/memory_initialization_vector[[:space:]]*=//I' \
      -e 's/[;,]//g' "$1" | grep -viE '[^0-9a-fx[:space:]]' | grep -vE '^[[:space:]]*$' > "$2"
}
coe2mem "$MIF/TwFctrCache_RNSConsts.coe"   "$RUNDIR/fft_rns_rom.mem"
coe2mem "$MIF/FFTStoredTwiddleFactors.coe" "$RUNDIR/fft_all_twiddle_rom.mem"

echo "=== running (cwd=$RUNDIR) ==="
( cd "$RUNDIR" && "$OBJ_DIR/V$TOP" ) 2>&1 | tee -a "$LOG"

echo "=== verdict ==="
if grep -qiE "assertion failed|%Error|Failed opening file" "$LOG"; then
  echo "$TOP RESULT: FAIL (assertion/error/file-open -- see $LOG)"
  exit 1
fi
if ! grep -qiE '\$finish|finish at' "$LOG"; then
  echo "$TOP RESULT: FAIL (did not reach \$finish -- see $LOG)"
  exit 1
fi
echo "$TOP RESULT: PASS (reached \$finish, zero assertion failures)"
