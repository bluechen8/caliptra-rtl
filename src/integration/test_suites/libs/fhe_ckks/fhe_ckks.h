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
// CKKS FHE accelerator firmware driver (VeeR-side, internal AHB).
// Register offsets match src/fhe/rtl/fhe_reg.rdl. The FHE block is an AHB
// responder at internal base 0x1005_0000 (CALIPTRA_SLAVE_SEL_FHE window).
//

#ifndef FHE_CKKS_H
  #define FHE_CKKS_H

#include "caliptra_defines.h"
#include "riscv_hw_if.h"

// Internal AHB base (VeeR view) -- must match CALIPTRA_SLAVE_BASE_ADDR[FHE].
#define CLP_FHE_REG_BASE_ADDR     0x10050000

// Register map v2 (src/fhe/rtl/fhe_reg.rdl).
#define FHE_REG_NAME0             (CLP_FHE_REG_BASE_ADDR + 0x00)
#define FHE_REG_NAME1             (CLP_FHE_REG_BASE_ADDR + 0x04)
#define FHE_REG_VERSION0          (CLP_FHE_REG_BASE_ADDR + 0x08)
#define FHE_REG_VERSION1          (CLP_FHE_REG_BASE_ADDR + 0x0C)
#define FHE_REG_CTRL              (CLP_FHE_REG_BASE_ADDR + 0x10)
#define FHE_REG_STATUS            (CLP_FHE_REG_BASE_ADDR + 0x14)
#define FHE_REG_CONFIG            (CLP_FHE_REG_BASE_ADDR + 0x18)
#define FHE_REG_CAP               (CLP_FHE_REG_BASE_ADDR + 0x1C)
#define FHE_REG_KV_RD_SEED_CTRL   (CLP_FHE_REG_BASE_ADDR + 0x20)
#define FHE_REG_KV_RD_SEED_STATUS (CLP_FHE_REG_BASE_ADDR + 0x24)
#define FHE_REG_XFER_STATUS       (CLP_FHE_REG_BASE_ADDR + 0x28)
#define FHE_REG_XFER_LEFT         (CLP_FHE_REG_BASE_ADDR + 0x2C)
#define FHE_REG_SLOT0_BASE_L      (CLP_FHE_REG_BASE_ADDR + 0x30)  // slot n at +8n

// Commands (FHE_CTRL[2:0])
#define FHE_CMD_NONE              0x0
#define FHE_CMD_ENCRYPT           0x1
#define FHE_CMD_KEYGEN            0x2
#define FHE_CMD_DECRYPT           0x4
#define FHE_CMD_RECOVER           0x5
#define FHE_CMD_REFRESH           0x6
#define FHE_CTRL_ZEROIZE          (1 << 3)
#define FHE_CTRL_INPUT_COMMIT     (1 << 4)

// STATUS fields
#define FHE_STATUS_READY          (1 << 0)
#define FHE_STATUS_VALID          (1 << 1)
#define FHE_STATUS_ERROR          (1 << 2)
#define FHE_STATUS_KEY_VALID      (1 << 3)
#define FHE_STATUS_ERR_CAUSE(s)   (((s) >> 4) & 0xF)
#define FHE_STATUS_COMMIT_WAIT    (1 << 8)
#define FHE_STATUS_DMA_LEASED     (1 << 9)

// ERR_CAUSE values
#define FHE_ERR_NONE              0
#define FHE_ERR_NO_KEY            1
#define FHE_ERR_BAD_L             2
#define FHE_ERR_BAD_OPCODE        3
#define FHE_ERR_NO_SEED           4
#define FHE_ERR_KV_READ           5
#define FHE_ERR_DMA_BUSY          6
#define FHE_ERR_BAD_LOGN          7
#define FHE_ERR_BAD_WORD          8
#define FHE_ERR_BAD_ADDR          9
#define FHE_ERR_TRANSPORT         10
#define FHE_ERR_ABORTED           11

// Expected identity values (see fhe_top.sv)
#define FHE_NAME0_EXP             0x534B4B43   // "CKKS"
#define FHE_VERSION0_EXP          0x3030322e   // "2.00"

void     fhe_zeroize(void);
uint32_t fhe_read_status(void);
// CONFIG = {SCALE[27:16], LOGN[7:4], L[3:0]}.
void     fhe_set_config(uint32_t limbs, uint32_t logn, uint32_t scale);
// Write slot base address `slot` (0..3).
void     fhe_set_slot(uint32_t slot, uint64_t addr);
// Read the KeyVault entry into the seed register (standard kv_read_ctrl_reg /
// kv_status_reg, see libs/keyvault); returns the final KV status.
uint32_t fhe_kv_seed_read(uint32_t entry);
// Issue a command and poll STATUS until VALID; returns the final STATUS word.
uint32_t fhe_run_poll(uint32_t cmd);

#endif
