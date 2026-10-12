#!/usr/bin/env bash
# Source Chipyard env.sh first. Use a current preprocessed Caliptra SV snapshot.
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "usage: $0 PREPROCESSED_CALIPTRA_SV NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi
fhe_test_dir=$(cd -- "$(dirname -- "$0")" && pwd)
fhe_preproc=$(realpath -- "$1")
fhe_test_out=$(realpath -m -- "$2")
if [[ -e "$fhe_test_out" ]]; then
    echo "refusing existing output directory: $fhe_test_out" >&2
    exit 2
fi
mkdir -p -- "$fhe_test_out"
verilator --binary --timing --top-module tb_axi_reset -Wno-fatal \
    --Mdir "$fhe_test_out/obj" "$fhe_preproc" "$fhe_test_dir/tb_axi_warm_reset.sv" \
    > "$fhe_test_out/build.log" 2>&1
"$fhe_test_out/obj/Vtb_axi_reset" > "$fhe_test_out/coordinated.log" 2>&1
"$fhe_test_out/obj/Vtb_axi_reset" +UNCOORDINATED > "$fhe_test_out/uncoordinated.log" 2>&1
cat "$fhe_test_out/coordinated.log" "$fhe_test_out/uncoordinated.log"
