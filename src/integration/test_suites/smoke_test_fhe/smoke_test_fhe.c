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
// FHE accelerator smoke test. Firmware-driven, reuses the caliptra_top_tb
// harness exactly like smoke_test_mldsa. Poll-based: drives the FHE AHB
// registers from VeeR.
//
//  - Against the Stage-0 stub: checks the observable contract (identity regs,
//    register R/W, command -> busy -> VALID).
//  - Against the FHE_WALKER datapath (B' 2c-step-3): additionally programs the
//    microsequencer seeds/scales/CONFIG + the 4 DMA pointer registers and runs
//    the KEYGEN -> ENCRYPT -> DECRYPT service sequence. The ciphertext rounds
//    through the dedicated FHE DMA to a TB DRAM model; the testbench backdoor-
//    checks recovered ~= input (the FW only drives control + polls STATUS,
//    since VeeR cannot reach the FHE DMA's external DRAM).
//
//  The seed/scale constants and the DRAM buffer layout MUST match the TB
//  (caliptra_top_tb FHE_WALKER block) and the green standalone fhe_top_dma_tb.
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

// ---- FHE round-trip parameters (must match the TB / fhe_top_dma_tb) ----
// Built for N=256 (LOGN=8); rebuild RTL with +define+FHE_N=256 to match.
#define FHE_SMOKE_LOGN   8
#define FHE_SMOKE_N      (1u << FHE_SMOKE_LOGN)
// STRIDE = max(N*8, 2KB), >=2KB-aligned per the AXI chunking contract.
#define FHE_STRIDE       ((FHE_SMOKE_N*8u > 2048u) ? (FHE_SMOKE_N*8u) : 2048u)
#define FHE_ADDR_P       (0u*FHE_STRIDE)   // plaintext  (TB preloads here)
#define FHE_ADDR_C0      (1u*FHE_STRIDE)   // ciphertext c0
#define FHE_ADDR_C1      (2u*FHE_STRIDE)   // ciphertext c1
#define FHE_ADDR_OUT     (3u*FHE_STRIDE)   // recovered slots (TB checks here)

// Seeds: any consistent set works for round-trip (decrypt inverts encrypt with
// the same resident sk). These mirror the green fhe_top_dma_tb constants.
#define FHE_KEYGEN_SEED  0xA105BEEF0006A001ULL
#define FHE_A_SEED       0x0006A002C0FFEE77ULL
#define FHE_ERR_SEED     0x2350E17152392F72ULL

// Scales: RT_SCALE = 17 + LOGN. rns_scale = RT_SCALE-52-1023-LOGN (LOGN cancels
// -> -1058; wrap into [0,4096): +4096 = 3038, N-independent). i2f = -(RT_SCALE).
#define FHE_RT_SCALE     (17 + FHE_SMOKE_LOGN)
#define FHE_RNS_SCALE    ((uint32_t)(FHE_RT_SCALE - 52 - 1023 - FHE_SMOKE_LOGN + 4096))
#define FHE_I2F_SCALE    ((uint32_t)(-(int32_t)FHE_RT_SCALE))

static void run_svc(const char *nm, uint32_t cmd) {
    uint32_t st = fhe_run_poll(cmd);
    if (st & FHE_STATUS_ERROR) {
        VPRINTF(LOW, "  FAIL: %s reported ERROR (status=0x%08x)\n", nm, st);
        errors++;
    } else {
        VPRINTF(LOW, "  ok  : %s complete (status=0x%08x)\n", nm, st);
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

    // 3) Clean slate, then program the microsequencer. (Register read/write is
    //    exercised below by the KGSEED0 / I2FSCALE read-backs on registers the
    //    real flow actually uses, so no separate scratch-register probe.)
    fhe_zeroize();

    // 4) Program the microsequencer: seeds, scales, CONFIG.L = 1.
    fhe_set_kg_seed (FHE_KEYGEN_SEED);
    fhe_set_a_seed  (FHE_A_SEED);
    fhe_set_err_seed(FHE_ERR_SEED);
    fhe_set_scales(FHE_RNS_SCALE, FHE_RNS_SCALE, FHE_I2F_SCALE);
    fhe_set_config(/*target_level (L)*/ 1, /*param_set_id*/ 0);
    check32("KGSEED0 rdbk",  lsu_read_32(FHE_REG_KGSEED0),  (uint32_t)(FHE_KEYGEN_SEED & 0xFFFFFFFF));
    check32("I2FSCALE rdbk", lsu_read_32(FHE_REG_I2FSCALE), FHE_I2F_SCALE);

    // 5) KEYGEN: materialize the resident secret key (no DMA).
    run_svc("KEYGEN", FHE_CMD_KEYGEN);

    // 6) ENCRYPT: plaintext @P -> ciphertext (c0 @C0, c1 @C1) via FHE DMA.
    fhe_set_ptr(0, FHE_ADDR_P);    // PTR0 = SRC plaintext
    fhe_set_ptr(2, FHE_ADDR_C0);   // PTR2 = DST c0
    fhe_set_ptr(3, FHE_ADDR_C1);   // PTR3 = DST c1
    run_svc("ENCRYPT", FHE_CMD_ENCRYPT);

    // 7) DECRYPT: ciphertext (c0 @C0, c1 @C1) -> recovered slots @OUT.
    fhe_set_ptr(0, FHE_ADDR_C0);   // PTR0 = SRC c0
    fhe_set_ptr(1, FHE_ADDR_C1);   // PTR1 = SRC c1
    fhe_set_ptr(2, FHE_ADDR_OUT);  // PTR2 = DST recovered
    run_svc("DECRYPT", FHE_CMD_DECRYPT);

    VPRINTF(LOW, "FHE control sequence done; TB checks recovered ~= input.\n");

    if (errors == 0) {
        VPRINTF(LOW, "FHE smoke test PASSED\n");
        SEND_STDOUT_CTRL(0xff);   // end test (pass)
    } else {
        VPRINTF(LOW, "FHE smoke test FAILED (%d error(s))\n", errors);
        SEND_STDOUT_CTRL(0x01);   // end test (fail)
    }

    while (1);
}
