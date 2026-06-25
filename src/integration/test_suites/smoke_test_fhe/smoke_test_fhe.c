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
// FHE accelerator smoke test (Stage-0 stub). Firmware-driven, reuses the
// caliptra_top_tb harness exactly like smoke_test_mldsa. Poll-based: drives
// the FHE AHB registers from VeeR and checks the observable contract of the
// behavioral stub (identity regs, register R/W, command -> busy -> VALID).
//

#include "caliptra_defines.h"
#include "caliptra_isr.h"
#include "riscv_hw_if.h"
#include "riscv-csr.h"
#include "printf.h"
#include "fhe_ckks.h"

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

void main(void) {
    VPRINTF(LOW, "----------------------------\n");
    VPRINTF(LOW, " Running FHE Smoke Test !!\n");
    VPRINTF(LOW, "----------------------------\n");

    init_interrupts();

    // 1) Identity registers
    check32("NAME0 (CKKS)",  lsu_read_32(FHE_REG_NAME0),    FHE_NAME0_EXP);
    check32("VERSION0",      lsu_read_32(FHE_REG_VERSION0), FHE_VERSION0_EXP);

    // 2) Idle status: READY=1, VALID=0
    check32("STATUS idle",   fhe_read_status() & (FHE_STATUS_READY | FHE_STATUS_VALID),
            FHE_STATUS_READY);

    // 3) Register read/write through the AHB responder
    fhe_set_src_addr(0x0000000089ABCDEFULL);
    check32("SRC_ADDR0 rdbk", lsu_read_32(FHE_REG_SRC_ADDR0), 0x89ABCDEF);
    fhe_set_config(/*target_level*/ 3, /*param_set_id*/ 2);
    check32("CONFIG rdbk",    lsu_read_32(FHE_REG_CONFIG), 0x00000023);

    // 4) Command flow: ENCRYPT -> busy -> VALID
    fhe_set_dst_addr(0x0000000080000000ULL);   // a DRAM dst pointer (stub ignores)
    uint32_t st = fhe_run_poll(FHE_CMD_ENCRYPT);
    check32("STATUS after ENCRYPT", st & (FHE_STATUS_READY | FHE_STATUS_VALID | FHE_STATUS_ERROR),
            FHE_STATUS_READY | FHE_STATUS_VALID);

    // 5) A second command (KEYGEN) also completes cleanly
    st = fhe_run_poll(FHE_CMD_KEYGEN);
    check32("STATUS after KEYGEN", st & (FHE_STATUS_VALID | FHE_STATUS_ERROR),
            FHE_STATUS_VALID);

    // 6) ZEROIZE clears the architectural registers and VALID
    fhe_zeroize();
    check32("SRC_ADDR0 after zeroize", lsu_read_32(FHE_REG_SRC_ADDR0), 0x00000000);
    check32("STATUS after zeroize",    fhe_read_status() & (FHE_STATUS_READY | FHE_STATUS_VALID),
            FHE_STATUS_READY);

    if (errors == 0) {
        VPRINTF(LOW, "FHE smoke test PASSED\n");
        SEND_STDOUT_CTRL(0xff);   // end test (pass)
    } else {
        VPRINTF(LOW, "FHE smoke test FAILED (%d error(s))\n", errors);
        SEND_STDOUT_CTRL(0x01);   // end test (fail)
    }

    while (1);
}
