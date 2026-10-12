#!/usr/bin/env bash
# Source Chipyard env.sh first. Focused Verilator test, not full-SoC validation.
# Extract the actual security latch instead of maintaining a second RTL model.
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "usage: $0 PREPROCESSED_CALIPTRA_SV NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi
fhe_test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fhe_preproc=$(realpath -- "$1")
fhe_test_out=$(realpath -m -- "$2")
if [[ -e "$fhe_test_out" ]]; then
    echo "refusing existing output directory: $fhe_test_out" >&2
    exit 2
fi
python3 - "$fhe_preproc" "$fhe_test_out" <<'PY'
from pathlib import Path
import sys

rtl, out = map(Path, sys.argv[1:])
text = rtl.read_text()
marker = text.index('unlock_caliptra_security_state <= 1;')
start = text.rfind('always_ff', 0, marker)
end = text.index('assign clear_obf_secrets_debugScanQ', marker)
block = text[start:end]
if start < 0 or 'assign debug_lock_or_scan_mode_switch' not in block:
    raise RuntimeError('security-state RTL boundary changed')
out.mkdir(parents=True, exist_ok=False)
(out / 'security_state_latch.svh').write_text(block)
PY
verilator --binary --timing --top-module tb_kv_warm_debug -Wno-fatal \
    --Mdir "$fhe_test_out/obj" "-I$fhe_test_out" \
    "$fhe_preproc" "$fhe_test_dir/tb_kv_warm_reset.sv" \
    > "$fhe_test_out/build.log" 2>&1
"$fhe_test_out/obj/Vtb_kv_warm_debug" > "$fhe_test_out/unlocked.log" 2>&1
"$fhe_test_out/obj/Vtb_kv_warm_debug" +LOCKED > "$fhe_test_out/locked.log" 2>&1
cat "$fhe_test_out/unlocked.log" "$fhe_test_out/locked.log"
python3 - "$fhe_preproc" "$fhe_test_out" "$fhe_test_dir/tb_kv_warm_reset.sv" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

rtl, out, fixture = map(Path, sys.argv[1:])
(out / 'result.json').write_text(json.dumps({
    'status': 'PASS', 'rtl': str(rtl),
    'rtl_sha256': hashlib.sha256(rtl.read_bytes()).hexdigest(),
    'security_latch_sha256': hashlib.sha256((out / 'security_state_latch.svh').read_bytes()).hexdigest(),
    'fixture_sha256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
    'scope': 'Real KeyVault and extracted RTL security latch. Unlocked warm reset flushes the key; locked warm reset retains it. No full-SoC claim.',
}, indent=2) + '\n')
PY
