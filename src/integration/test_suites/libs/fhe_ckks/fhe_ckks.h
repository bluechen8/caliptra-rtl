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

// Internal AHB base (VeeR view) — must match CALIPTRA_SLAVE_BASE_ADDR[FHE].
#define CLP_FHE_REG_BASE_ADDR     0x10050000

#define FHE_REG_NAME0             (CLP_FHE_REG_BASE_ADDR + 0x00)
#define FHE_REG_NAME1             (CLP_FHE_REG_BASE_ADDR + 0x04)
#define FHE_REG_VERSION0          (CLP_FHE_REG_BASE_ADDR + 0x08)
#define FHE_REG_VERSION1          (CLP_FHE_REG_BASE_ADDR + 0x0C)
#define FHE_REG_CTRL              (CLP_FHE_REG_BASE_ADDR + 0x10)
#define FHE_REG_STATUS            (CLP_FHE_REG_BASE_ADDR + 0x14)
#define FHE_REG_SRC_ADDR0         (CLP_FHE_REG_BASE_ADDR + 0x18)
#define FHE_REG_SRC_ADDR1         (CLP_FHE_REG_BASE_ADDR + 0x1C)
#define FHE_REG_DST_ADDR0         (CLP_FHE_REG_BASE_ADDR + 0x20)
#define FHE_REG_DST_ADDR1         (CLP_FHE_REG_BASE_ADDR + 0x24)
#define FHE_REG_KEY_DST_ADDR0     (CLP_FHE_REG_BASE_ADDR + 0x28)
#define FHE_REG_KEY_DST_ADDR1     (CLP_FHE_REG_BASE_ADDR + 0x2C)
#define FHE_REG_CONFIG            (CLP_FHE_REG_BASE_ADDR + 0x30)
// Stage-B' 2c microsequencer inputs: program-level seeds (EXE sampling) +
// firmware-computed scales (INS scale-field patches). See microseq doc 5.1.
#define FHE_REG_KGSEED0           (CLP_FHE_REG_BASE_ADDR + 0x34)
#define FHE_REG_KGSEED1           (CLP_FHE_REG_BASE_ADDR + 0x38)
#define FHE_REG_ASEED0            (CLP_FHE_REG_BASE_ADDR + 0x3C)
#define FHE_REG_ASEED1            (CLP_FHE_REG_BASE_ADDR + 0x40)
#define FHE_REG_ESEED0            (CLP_FHE_REG_BASE_ADDR + 0x44)
#define FHE_REG_ESEED1            (CLP_FHE_REG_BASE_ADDR + 0x48)
#define FHE_REG_KGSCALE           (CLP_FHE_REG_BASE_ADDR + 0x4C)
#define FHE_REG_ENCSCALE          (CLP_FHE_REG_BASE_ADDR + 0x50)
#define FHE_REG_I2FSCALE          (CLP_FHE_REG_BASE_ADDR + 0x54)
// B' 2c-step-2: four DMA base-pointer registers (byte addresses of the poly
// buffers in DRAM), indexed by the walker's PTR index 0..3.
#define FHE_REG_PTR0_LO           (CLP_FHE_REG_BASE_ADDR + 0x58)
#define FHE_REG_PTR0_HI           (CLP_FHE_REG_BASE_ADDR + 0x5C)
#define FHE_REG_PTR1_LO           (CLP_FHE_REG_BASE_ADDR + 0x60)
#define FHE_REG_PTR1_HI           (CLP_FHE_REG_BASE_ADDR + 0x64)
#define FHE_REG_PTR2_LO           (CLP_FHE_REG_BASE_ADDR + 0x68)
#define FHE_REG_PTR2_HI           (CLP_FHE_REG_BASE_ADDR + 0x6C)
#define FHE_REG_PTR3_LO           (CLP_FHE_REG_BASE_ADDR + 0x70)
#define FHE_REG_PTR3_HI           (CLP_FHE_REG_BASE_ADDR + 0x74)

// Commands (FHE_CTRL[2:0])
#define FHE_CMD_NONE              0x0
#define FHE_CMD_ENCRYPT           0x1
#define FHE_CMD_KEYGEN            0x2
#define FHE_CMD_REENC             0x3
#define FHE_CMD_DECRYPT           0x4
#define FHE_CTRL_ZEROIZE          (1 << 3)

// Status bits
#define FHE_STATUS_READY          (1 << 0)
#define FHE_STATUS_VALID          (1 << 1)
#define FHE_STATUS_DMA_REQ        (1 << 2)
#define FHE_STATUS_ERROR          (1 << 3)

// Expected identity values (see fhe_params_pkg.sv)
#define FHE_NAME0_EXP             0x534B4B43   // "CKKS"
#define FHE_VERSION0_EXP          0x3030312e   // "1.00"

void     fhe_zeroize(void);
uint32_t fhe_read_status(void);
void     fhe_set_dst_addr(uint64_t addr);
void     fhe_set_src_addr(uint64_t addr);
void     fhe_set_config(uint8_t target_level, uint8_t param_set_id);
// Issue a command and poll STATUS until VALID; returns the final STATUS word.
uint32_t fhe_run_poll(uint32_t cmd);

// Stage-B' 2c microsequencer programming (write a 64-bit value lo/hi).
void     fhe_set_kg_seed(uint64_t seed);
void     fhe_set_a_seed(uint64_t seed);
void     fhe_set_err_seed(uint64_t seed);
void     fhe_set_scales(uint32_t kg_scale, uint32_t enc_scale, uint32_t i2f_scale);
// Write DMA base pointer reg `idx` (0..3) with a 64-bit DRAM byte address.
void     fhe_set_ptr(uint32_t idx, uint64_t addr);

#endif
