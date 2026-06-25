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

uint32_t fhe_run_poll(uint32_t cmd) {
    uint32_t st;
    // Wait until ready.
    while ((lsu_read_32(FHE_REG_STATUS) & FHE_STATUS_READY) == 0);
    // Issue the command (self-clearing in HW).
    lsu_write_32(FHE_REG_CTRL, cmd);
    // Poll until the operation reports VALID.
    do {
        st = lsu_read_32(FHE_REG_STATUS);
    } while ((st & FHE_STATUS_VALID) == 0);
    return st;
}
