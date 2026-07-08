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
// C'-2 FHE free-run PRNG smoke test (firmware self-serve reseed).
//
//   Exercises the full mandatory-reseed handshake at the caliptra_top_tb level:
//     1. enable CSRNG (SW application interface, GENBITS) as the entropy source,
//     2. enable free-run + KEYGEN (which marks the a/e0 stream unseeded),
//     3. issue ENCRYPT with NO reseed -> HW STALLS and raises
//        STATUS.RESEED_REQ_PENDING (the enforcement: no encrypt with stale entropy),
//     4. firmware reads a fresh 64-bit seed from CSRNG GENBITS and writes it to
//        ENTSEED + RESEED_REQ (the doorbell) -> the stalled encrypt is RELEASED,
//     5. DECRYPT; the TB backdoor-checks recovered ~= input.
//
//   This is the software counterpart of the +FREERUN case in the standalone
//   src/fhe/tb/fhe_top_dma_tb.sv. CSRNG output is deterministic in sim, so the
//   round-trip still recovers (encrypt/decrypt cancel for any a/e0).
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
    if (got != exp) { VPRINTF(LOW, "  FAIL: %s got=0x%08x exp=0x%08x\n", name, got, exp); errors++; }
    else            { VPRINTF(LOW, "  ok  : %s = 0x%08x\n", name, got); }
}

// Issue a command that runs to completion without a mid-command stall (KEYGEN,
// DECRYPT) and check for ERROR. (ENCRYPT is handled specially -- it stalls.)
static void run_svc(const char *nm, uint32_t cmd) {
    uint32_t st = fhe_run_poll(cmd);
    if (st & FHE_STATUS_ERROR) { VPRINTF(LOW, "  FAIL: %s error 0x%08x\n", nm, st); errors++; }
    else                       { VPRINTF(LOW, "  ok  : %s complete\n", nm); }
}

// ---- round-trip parameters (must match the TB / fhe_top_dma_tb) ----
#define FHE_SMOKE_LOGN   8
#define FHE_SMOKE_N      (1u << FHE_SMOKE_LOGN)
#define FHE_STRIDE       ((FHE_SMOKE_N*8u > 2048u) ? (FHE_SMOKE_N*8u) : 2048u)
#define FHE_ADDR_P       (0u*FHE_STRIDE)
#define FHE_ADDR_C0      (1u*FHE_STRIDE)
#define FHE_ADDR_C1      (2u*FHE_STRIDE)
#define FHE_ADDR_OUT     (3u*FHE_STRIDE)

#define FHE_KEYGEN_SEED  0xA105BEEF0006A001ULL
#define FHE_A_SEED       0x0006A002C0FFEE77ULL
#define FHE_ERR_SEED     0x2350E17152392F72ULL
#define FHE_RT_SCALE     (17 + FHE_SMOKE_LOGN)
#define FHE_RNS_SCALE    ((uint32_t)(FHE_RT_SCALE - 52 - 1023 - FHE_SMOKE_LOGN + 4096))
#define FHE_I2F_SCALE    ((uint32_t)(-(int32_t)FHE_RT_SCALE))

// ---- CSRNG SW-application entropy (mirrors smoke_test_trng) ----
static void poll_mask(uint32_t addr, uint32_t mask) {
    while ((lsu_read_32(addr) & mask) != mask);
}

static void enable_csrng(void) {
    VPRINTF(LOW, "  enabling entropy_src + csrng (SW app)\n");
    lsu_write_32(CLP_ENTROPY_SRC_REG_CONF,          0x2649999);
    lsu_write_32(CLP_ENTROPY_SRC_REG_MODULE_ENABLE, 0x6);
    lsu_write_32(CLP_CSRNG_REG_CTRL,                0x666);
    lsu_write_32(CLP_CSRNG_REG_CMD_REQ,             0x901);   // instantiate
    poll_mask(CLP_ENTROPY_SRC_REG_DEBUG_STATUS,
              ENTROPY_SRC_REG_DEBUG_STATUS_MAIN_SM_BOOT_DONE_MASK);
}

// One CSRNG generate -> a fresh 64-bit seed (drains the 128-bit GENBITS packet).
static uint64_t csrng_seed64(void) {
    uint32_t w0, w1;
    lsu_write_32(CLP_CSRNG_REG_CMD_REQ, 0x1003);              // generate (128b packet)
    poll_mask(CLP_CSRNG_REG_GENBITS_VLD, CSRNG_REG_GENBITS_VLD_GENBITS_VLD_MASK);
    w0 = lsu_read_32(CLP_CSRNG_REG_GENBITS);
    w1 = lsu_read_32(CLP_CSRNG_REG_GENBITS);
    lsu_read_32(CLP_CSRNG_REG_GENBITS);                       // drain the remaining
    lsu_read_32(CLP_CSRNG_REG_GENBITS);                       // 64b of the packet
    return ((uint64_t)w1 << 32) | w0;
}

void main(void) {
    VPRINTF(LOW, "----------------------------------\n");
    VPRINTF(LOW, " Running FHE free-run Smoke Test !!\n");
    VPRINTF(LOW, "----------------------------------\n");

    init_interrupts();

    check32("NAME0 (CKKS)", lsu_read_32(FHE_REG_NAME0),    FHE_NAME0_EXP);
    check32("STATUS idle",  fhe_read_status() & (FHE_STATUS_READY | FHE_STATUS_VALID),
            FHE_STATUS_READY);

    // 1) entropy source
    enable_csrng();

    // 2) program the microsequencer + enable free-run
    fhe_zeroize();
    fhe_set_kg_seed (FHE_KEYGEN_SEED);
    fhe_set_a_seed  (FHE_A_SEED);      // legacy per-pass seeds: unused in free-run
    fhe_set_err_seed(FHE_ERR_SEED);
    fhe_set_scales(FHE_RNS_SCALE, FHE_RNS_SCALE, FHE_I2F_SCALE);
    fhe_set_config(/*L*/ 1, /*param_set_id*/ 0);
    fhe_set_freerun(1);

    // 3) KEYGEN: resident secret key; marks the a/e0 stream unseeded.
    run_svc("KEYGEN", FHE_CMD_KEYGEN);

    // 4) ENCRYPT with NO reseed -> must STALL (enforcement), observable via
    //    STATUS.RESEED_REQ_PENDING. Then service it with fresh CSRNG entropy.
    fhe_set_ptr(0, FHE_ADDR_P);
    fhe_set_ptr(2, FHE_ADDR_C0);
    fhe_set_ptr(3, FHE_ADDR_C1);
    fhe_issue(FHE_CMD_ENCRYPT);
    {
        uint32_t st; int guard = 0;
        do { st = fhe_read_status(); guard++; }
        while (!(st & (FHE_STATUS_RESEED_REQ_PENDING | FHE_STATUS_VALID)) && guard < 2000000);
        if (st & FHE_STATUS_VALID) {
            VPRINTF(LOW, "  FAIL: ENCRYPT completed with NO reseed (enforcement broken)\n"); errors++;
        } else if (st & FHE_STATUS_RESEED_REQ_PENDING) {
            VPRINTF(LOW, "  ok  : ENCRYPT stalled, STATUS.RESEED_REQ_PENDING set\n");
        } else {
            VPRINTF(LOW, "  FAIL: ENCRYPT neither stalled nor done (status=0x%08x)\n", st); errors++;
        }
    }
    // service the request: fresh 64-bit seed from CSRNG -> doorbell (releases it).
    {
        uint64_t ent = csrng_seed64();
        VPRINTF(LOW, "  reseed a/e0 stream with CSRNG seed 0x%08x%08x\n",
                (uint32_t)(ent >> 32), (uint32_t)ent);
        fhe_reseed(ent);
        uint32_t st = fhe_poll_valid();
        if (st & FHE_STATUS_ERROR) { VPRINTF(LOW, "  FAIL: ENCRYPT error 0x%08x\n", st); errors++; }
        else                       { VPRINTF(LOW, "  ok  : ENCRYPT complete after CSRNG reseed\n"); }
    }

    // 5) DECRYPT (no sampling -> no stall).
    fhe_set_ptr(0, FHE_ADDR_C0);
    fhe_set_ptr(1, FHE_ADDR_C1);
    fhe_set_ptr(2, FHE_ADDR_OUT);
    run_svc("DECRYPT", FHE_CMD_DECRYPT);

    VPRINTF(LOW, "FHE free-run control sequence done; TB checks recovered ~= input.\n");

    if (errors == 0) { VPRINTF(LOW, "FHE free-run smoke test PASSED\n"); SEND_STDOUT_CTRL(0xff); }
    else             { VPRINTF(LOW, "FHE free-run smoke test FAILED (%d error(s))\n", errors); SEND_STDOUT_CTRL(0x01); }

    while (1);
}
