#!/usr/bin/env python3
"""Independent N=256 coefficient-recovery vectors (direct polynomial evaluation).

c1=0 and c0=NTT(m), so recovery must produce m modulo each prime. m contains
signed 93-bit values, including values outside the single-prime centered range.
This is an arithmetic test ciphertext, not a confidentiality-protecting encryption.
No FFT, butterfly implementation, or DUT-produced expected output is used.
"""
from pathlib import Path
import random
import sys

N = 256
QS = [(1 << 46) - (9 << 24) + 1, (1 << 47) - (1 << 24) + 1]


def root(q):
    for a in range(2, q):
        g = pow(a, (q - 1) // (2 * N), q)
        if pow(g, N, q) == q - 1:
            return min(pow(g, k, q) for k in range(1, 2 * N, 2))
    raise ValueError("no root")


def main(directory):
    out = Path(directory)
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(0xA108)
    product = QS[0] * QS[1]
    coeff = [rng.randrange(-(product // 2), product // 2 + 1) for _ in range(N)]
    coeff[:7] = [0, 1, -1, QS[0] + 123, -QS[0] - 456, product // 2, -(product // 2)]
    transformed, residues = [], []
    for q in QS:
        g = root(q)
        for index in range(N):
            reversed_index = int(f'{index:08b}'[::-1], 2)
            x = pow(g, 2 * reversed_index + 1, q)
            value = 0
            for c in reversed(coeff):
                value = (value * x + c) % q
            transformed.append(value)
        residues.extend(c % q for c in coeff)
    for name, values in [('recovery_ntt.hex', transformed), ('recovery_coeff.hex', residues)]:
        (out / name).write_text(''.join(f'{v:016x}\n' for v in values))


if __name__ == '__main__':
    main(sys.argv[1])
