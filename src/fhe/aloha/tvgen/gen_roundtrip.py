#!/usr/bin/env python3
"""Rung 5c: generate inputs for the self-contained composed-core round-trip.

The keypair (sk, pk0, pk1) is derived ENTIRELY in hardware by the TB (sk=poly"1"
-> HW NTT; pk1 -> HW key-sample; pk0 = -MontMul(pk1,sk) via HW PWM), so its
Montgomery/root convention is co-designed and needs no host reproduction. This
script only emits the plaintext message and the PRNG seeds; the TB closes the
loop (encrypt then decrypt) and checks recovered ~= input.

Usage: gen_roundtrip.py <LOGN> <out_dir> [seed]
Emits (into out_dir): input.txt (N doubles, real/imag interleaved for N/2 slots),
pk1_seeds.txt (one seed), error_seed.txt (one seed). Scale/qm/k are TB constants.
"""
import sys
import struct
import random


def d2h(x):
    return f'{struct.unpack("<Q", struct.pack("<d", x))[0]:016x}'


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    logn = int(sys.argv[1])
    out = sys.argv[2]
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1234
    n = 1 << logn
    rng = random.Random(seed)

    # N/2 complex slots, magnitudes O(1) like the shipped N=8192 vectors.
    vals = []
    for _ in range(n // 2):
        vals.append(rng.uniform(-2.0, 2.0))   # real
        vals.append(rng.uniform(-2.0, 2.0))   # imag
    with open(f'{out}/input.txt', 'w') as f:
        f.write('\n'.join(d2h(v) for v in vals) + '\n')

    # 64-bit high-entropy seeds (avoid 0).
    pk1_seed = rng.getrandbits(64) | 1
    err_seed = rng.getrandbits(64) | 1
    open(f'{out}/pk1_seeds.txt', 'w').write(f'{pk1_seed:016x}\n')
    open(f'{out}/error_seed.txt', 'w').write(f'{err_seed:016x}\n')
    print(f'N={n}: wrote input.txt ({len(vals)} doubles), '
          f'pk1_seed=0x{pk1_seed:016x}, error_seed=0x{err_seed:016x}')


if __name__ == '__main__':
    main()
