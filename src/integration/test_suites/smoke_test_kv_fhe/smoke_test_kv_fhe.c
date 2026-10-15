// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// FHE accelerator KeyVault smoke test (register map v2). Firmware-driven on the
// caliptra_top_tb harness, like smoke_test_mldsa. Poll-based.
//
//  - The TB backdoor (opcode 0xc6) provisions a known 160-bit seed into
//    KeyVault slot 9 with read permission for client 2 (the FHE seed reader);
//    caliptra_top_tb checks the seed the sampler receives matches it.
//  - Firmware reads the seed through KV_RD_SEED_CTRL, runs KEYGEN and checks
//    KEY_VALID, then exercises the command preconditions (no seed, illegal
//    opcode, no key after ZEROIZE). No polynomial data moves: this harness has
//    no stream service.
//
#include "caliptra_defines.h"
#include "caliptra_isr.h"
#include "riscv_hw_if.h"
#include "riscv-csr.h"
#include "printf.h"
#include "fhe_ckks.h"
#include "keyvault.h"

volatile char*    stdout     = (char *)STDOUT;
volatile uint32_t intr_count = 0;
#ifdef CPT_VERBOSITY
    enum printf_verbosity verbosity_g = CPT_VERBOSITY;
#else
    enum printf_verbosity verbosity_g = LOW;
#endif

volatile caliptra_intr_received_s cptra_intr_rcv = {0};

static int errors = 0;

static void check32(const char *name, uint32_t got, uint32_t exp) {
    if (got != exp) {
        VPRINTF(LOW, "  FAIL: %s got=0x%08x exp=0x%08x\n", name, got, exp);
        errors++;
    } else {
        VPRINTF(LOW, "  ok  : %s = 0x%08x\n", name, got);
    }
}

// Built for N=256 (LOGN=8); rebuild RTL with +define+FHE_N=256 to match.
#define FHE_SMOKE_LOGN   8
// KeyVault slot the TB backdoor (0xc6) provisions with the FHE seed.
#define FHE_KV_ENTRY     9u
// RNS encode scale field for 2^(17+LOGN): RT_SCALE-52-1023-LOGN, wrapped to 12 bits.
#define FHE_RT_SCALE     (17 + FHE_SMOKE_LOGN)
#define FHE_RNS_SCALE    ((uint32_t)(FHE_RT_SCALE - 52 - 1023 - FHE_SMOKE_LOGN + 4096))

static void expect_status(const char *nm, uint32_t st, uint32_t error, uint32_t cause) {
    uint32_t got_err = (st & FHE_STATUS_ERROR) ? 1u : 0u;
    if (got_err != error || FHE_STATUS_ERR_CAUSE(st) != cause) {
        VPRINTF(LOW, "  FAIL: %s status=0x%08x (expected error=%d cause=%d)\n", nm, st, error, cause);
        errors++;
    } else {
        VPRINTF(LOW, "  ok  : %s status=0x%08x\n", nm, st);
    }
}

void main(void) {
    uint32_t st;
    VPRINTF(LOW, "----------------------------\n");
    VPRINTF(LOW, " Running FHE KeyVault Smoke Test !!\n");
    VPRINTF(LOW, "----------------------------\n");

    init_interrupts();

    // 1) Identity and reset status: READY, no completion, no key.
    check32("NAME0 (CKKS)",  lsu_read_32(FHE_REG_NAME0),    FHE_NAME0_EXP);
    check32("VERSION0",      lsu_read_32(FHE_REG_VERSION0), FHE_VERSION0_EXP);
    check32("STATUS idle",   fhe_read_status() & (FHE_STATUS_READY | FHE_STATUS_VALID | FHE_STATUS_KEY_VALID),
            FHE_STATUS_READY);
    fhe_set_config(2, FHE_SMOKE_LOGN, FHE_RNS_SCALE);

    // 2) KEYGEN without a seed read is refused.
    expect_status("KEYGEN without seed", fhe_run_poll(FHE_CMD_KEYGEN), 1, FHE_ERR_NO_SEED);

    // 3) Provision KeyVault slot 9 (TB backdoor), read it, then KEYGEN.
    lsu_write_32(STDOUT, (FHE_KV_ENTRY << 8) | 0xc6);
    st = fhe_kv_seed_read(FHE_KV_ENTRY);
    check32("KV seed read error", st & KV_RD_STATUS_ERROR_MASK, 0);
    expect_status("KEYGEN", fhe_run_poll(FHE_CMD_KEYGEN), 0, FHE_ERR_NONE);
    check32("KEY_VALID after KEYGEN", fhe_read_status() & FHE_STATUS_KEY_VALID, FHE_STATUS_KEY_VALID);
    check32("seed consumed", lsu_read_32(FHE_REG_KV_RD_SEED_STATUS) & KV_RD_STATUS_VALID_MASK, 0);

    // 4) Preconditions.
    expect_status("KEYGEN with consumed seed", fhe_run_poll(FHE_CMD_KEYGEN), 1, FHE_ERR_NO_SEED);
    expect_status("opcode 011", fhe_run_poll(0x3), 1, FHE_ERR_BAD_OPCODE);
    check32("KEY_VALID after refusals", fhe_read_status() & FHE_STATUS_KEY_VALID, FHE_STATUS_KEY_VALID);
    fhe_zeroize();
    check32("KEY_VALID after ZEROIZE", fhe_read_status() & FHE_STATUS_KEY_VALID, 0);
    fhe_set_config(2, FHE_SMOKE_LOGN, FHE_RNS_SCALE);
    expect_status("ENCRYPT without key", fhe_run_poll(FHE_CMD_ENCRYPT), 1, FHE_ERR_NO_KEY);

    if (errors == 0) {
        VPRINTF(LOW, "FHE smoke test PASSED\n");
        SEND_STDOUT_CTRL(0xff);   // end test (pass)
    } else {
        VPRINTF(LOW, "FHE smoke test FAILED (%d error(s))\n", errors);
        SEND_STDOUT_CTRL(0x01);   // end test (fail)
    }

    while (1);
}
