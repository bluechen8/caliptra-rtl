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
// CKKS FHE accelerator firmware driver (register map v2). Poll-based: no
// interrupt dependency.
//

#include "fhe_ckks.h"
#include "keyvault.h"
#include "printf.h"

void fhe_zeroize(void) {
    lsu_write_32(FHE_REG_CTRL, FHE_CTRL_ZEROIZE);
}

uint32_t fhe_read_status(void) {
    return lsu_read_32(FHE_REG_STATUS);
}

void fhe_set_config(uint32_t limbs, uint32_t logn, uint32_t scale) {
    lsu_write_32(FHE_REG_CONFIG, ((scale & 0xFFFu) << 16) | ((logn & 0xFu) << 4) | (limbs & 0xFu));
}

void fhe_set_slot(uint32_t slot, uint64_t addr) {
    uintptr_t lo = (uintptr_t)FHE_REG_SLOT0_BASE_L + (uintptr_t)slot * 8u;
    lsu_write_32(lo,     (uint32_t)(addr & 0xFFFFFFFF));
    lsu_write_32(lo + 4, (uint32_t)(addr >> 32));
}

uint32_t fhe_kv_seed_read(uint32_t entry) {
    uint32_t st;
    kv_read_ctrl(FHE_REG_KV_RD_SEED_CTRL, entry);
    do {
        st = lsu_read_32(FHE_REG_KV_RD_SEED_STATUS);
    } while ((st & KV_RD_STATUS_VALID_MASK) == 0);
    return st;
}

static void fhe_issue(uint32_t cmd) {
    while ((lsu_read_32(FHE_REG_STATUS) & FHE_STATUS_READY) == 0);
    lsu_write_32(FHE_REG_CTRL, cmd);
}

static uint32_t fhe_poll_valid(void) {
    uint32_t st;
    do {
        st = lsu_read_32(FHE_REG_STATUS);
    } while ((st & FHE_STATUS_VALID) == 0);
    return st;
}

uint32_t fhe_run_poll(uint32_t cmd) {
    fhe_issue(cmd);
    return fhe_poll_valid();
}
