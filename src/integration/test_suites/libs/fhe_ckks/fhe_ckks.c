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
// CKKS FHE accelerator firmware driver. Poll-based (no interrupt dependency)
// so it works against the Stage-0 stub before the FHE PIC line / ISR is wired.
//

#include "fhe_ckks.h"
#include "printf.h"

void fhe_zeroize(void) {
    lsu_write_32(FHE_REG_CTRL, FHE_CTRL_ZEROIZE);
}

uint32_t fhe_read_status(void) {
    return lsu_read_32(FHE_REG_STATUS);
}

void fhe_set_src_addr(uint64_t addr) {
    lsu_write_32(FHE_REG_SRC_ADDR0, (uint32_t)(addr & 0xFFFFFFFF));
    lsu_write_32(FHE_REG_SRC_ADDR1, (uint32_t)(addr >> 32));
}

void fhe_set_dst_addr(uint64_t addr) {
    lsu_write_32(FHE_REG_DST_ADDR0, (uint32_t)(addr & 0xFFFFFFFF));
    lsu_write_32(FHE_REG_DST_ADDR1, (uint32_t)(addr >> 32));
}

void fhe_set_config(uint8_t target_level, uint8_t param_set_id) {
    uint32_t cfg = (target_level & 0xF) | ((uint32_t)param_set_id << 4);
    lsu_write_32(FHE_REG_CONFIG, cfg);
}

uint32_t fhe_poll_valid(void) {
    uint32_t st;
    do {
        st = lsu_read_32(FHE_REG_STATUS);
    } while ((st & FHE_STATUS_VALID) == 0);
    return st;
}

uint32_t fhe_run_poll(uint32_t cmd) {
    fhe_issue(cmd);            // wait READY + write CTRL
    return fhe_poll_valid();   // poll until VALID
}

void fhe_set_kg_seed(uint64_t seed) {
    lsu_write_32(FHE_REG_KGSEED0, (uint32_t)(seed & 0xFFFFFFFF));
    lsu_write_32(FHE_REG_KGSEED1, (uint32_t)(seed >> 32));
}

void fhe_set_a_seed(uint64_t seed) {
    lsu_write_32(FHE_REG_ASEED0, (uint32_t)(seed & 0xFFFFFFFF));
    lsu_write_32(FHE_REG_ASEED1, (uint32_t)(seed >> 32));
}

void fhe_set_err_seed(uint64_t seed) {
    lsu_write_32(FHE_REG_ESEED0, (uint32_t)(seed & 0xFFFFFFFF));
    lsu_write_32(FHE_REG_ESEED1, (uint32_t)(seed >> 32));
}

void fhe_set_scales(uint32_t kg_scale, uint32_t enc_scale, uint32_t i2f_scale) {
    lsu_write_32(FHE_REG_KGSCALE,  kg_scale);
    lsu_write_32(FHE_REG_ENCSCALE, enc_scale);
    lsu_write_32(FHE_REG_I2FSCALE, i2f_scale);
}

void fhe_set_ptr(uint32_t idx, uint64_t addr) {
    // PTR0..3 are at base+0x58, each 8 bytes (lo,hi).
    uintptr_t lo = (uintptr_t)FHE_REG_PTR0_LO + (uintptr_t)idx * 8u;
    lsu_write_32(lo,     (uint32_t)(addr & 0xFFFFFFFF));
    lsu_write_32(lo + 4, (uint32_t)(addr >> 32));
}

void fhe_set_kgkv(uint32_t read_entry, uint32_t en) {
    // KGKV_CTRL: bit0 = KV_EN, bits[8:4] = READ_ENTRY.
    lsu_write_32(FHE_REG_KGKV_CTRL, ((read_entry & 0x1Fu) << 4) | (en ? 1u : 0u));
}

void fhe_set_freerun(uint32_t en) {
    // RNG_CTRL.FREERUN_EN (bit0); leave RESEED_REQ (bit1) clear.
    lsu_write_32(FHE_REG_RNG_CTRL, en ? FHE_RNG_CTRL_FREERUN_EN : 0u);
}

void fhe_reseed(uint64_t entseed) {
    // Doorbell: publish the CSRNG-sourced seed, then FREERUN_EN | RESEED_REQ. The
    // ENTSEED/RNG_CTRL regs are busy-writable, so this also RELEASES a first-encrypt
    // that is stalled in RESEED_REQ_PENDING.
    lsu_write_32(FHE_REG_ENTSEED0, (uint32_t)(entseed & 0xFFFFFFFF));
    lsu_write_32(FHE_REG_ENTSEED1, (uint32_t)(entseed >> 32));
    lsu_write_32(FHE_REG_RNG_CTRL, FHE_RNG_CTRL_FREERUN_EN | FHE_RNG_CTRL_RESEED_REQ);
}

void fhe_issue(uint32_t cmd) {
    // Fire-and-return (no completion poll): used when the caller must service a
    // mid-command request (e.g. RESEED_REQ_PENDING) before the op can finish.
    while ((lsu_read_32(FHE_REG_STATUS) & FHE_STATUS_READY) == 0);
    lsu_write_32(FHE_REG_CTRL, cmd);
}
