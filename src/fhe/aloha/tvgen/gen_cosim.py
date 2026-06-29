#!/usr/bin/env python3
"""Rung 7a cosim: generate the two plaintext messages for the client<->server
ct+ct interop test.

The keypair is derived entirely in HW (sk-scheme, KEYGEN_SEED in the TB); the
fresh (a, e0) per ciphertext come from TB seeds (A_SEED/ERR_SEED, A_SEED2/
ERR_SEED2). So this script only emits the two plaintext slot vectors m1, m2;
the cosim closes the loop (Aloha encrypt -> Lattigo ring.Add -> Aloha decrypt)
and checks recovered ~= m1 + m2.

Usage: gen_cosim.py <LOGN> <out_dir> [seed]
Emits (into out_dir): input.txt (m1) and input2.txt (m2), each N doubles
(real/imag interleaved for N/2 complex slots), magnitudes O(1).
"""
import sys
import struct
import random


def d2h(x):
    return f'{struct.unpack("<Q", struct.pack("<d", x))[0]:016x}'


def emit(path, n, rng):
    vals = []
    for _ in range(n // 2):
        vals.append(rng.uniform(-2.0, 2.0))   # real
        vals.append(rng.uniform(-2.0, 2.0))   # imag
    with open(path, 'w') as f:
        f.write('\n'.join(d2h(v) for v in vals) + '\n')
    return len(vals)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    logn = int(sys.argv[1])
    out = sys.argv[2]
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1234
    n = 1 << logn
    rng = random.Random(seed)
    n1 = emit(f'{out}/input.txt',  n, rng)
    n2 = emit(f'{out}/input2.txt', n, rng)
    print(f'N={n}: wrote input.txt ({n1} doubles) + input2.txt ({n2} doubles)')


if __name__ == '__main__':
    main()
