#!/usr/bin/env python3
"""Rung 6 keygen cross-check: verify the HW-derived s_ntt is the genuine NTT of
the sampled ternary secret s, independently of the round-trip (which would pass
even for a garbage key because the encrypt-negate and decrypt MontMuls cancel).

The TB dumps (into <dir>):
  hw_s_tern.txt  -- N raw ternary coeffs (decimal -1/0/+1), the sampled secret s
  hw_s_ntt.txt   -- N hex residues, the HW forward-NTT of s (NTT_V readback,
                    standard domain, HW bit-reversed order)

We map s -> residues mod q0, run the validated Go NTT oracle (Aloha root, same
bit-reversed output order), and require a bit-exact match against hw_s_ntt.txt.

Usage: check_keygen.py <dir> [LOGN]   (LOGN inferred from file length if omitted)
Modulus 0 (the TB keygen modulus): q0 = 2^46 - 9*2^24 + 1.
"""
import os
import subprocess
import sys

Q0 = (1 << 46) - (9 << 24) + 1   # 0x3ffff7000001, TB modulus 0 (QM0=9, k=0)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    d = sys.argv[1]
    s = [int(x) for x in open(f'{d}/hw_s_tern.txt').read().split()]
    n = len(s)
    logn = int(sys.argv[2]) if len(sys.argv) > 2 else n.bit_length() - 1
    assert (1 << logn) == n, f'N={n} not a power of two / LOGN mismatch'

    # ternary -> residue mod q0  ( -1 -> q0-1, 0 -> 0, +1 -> 1 )
    res = [(c % Q0) for c in s]
    resfile = f'{d}/s_residues.txt'
    with open(resfile, 'w') as f:
        f.write('\n'.join(f'{v:x}' for v in res) + '\n')

    outfile = f'{d}/s_ntt_oracle.txt'
    here = os.path.dirname(os.path.abspath(__file__))
    subprocess.run(['go', 'run', '.', 'ntt', str(logn), f'0x{Q0:x}', resfile, outfile],
                   cwd=here, check=True)

    oracle = [int(x, 16) for x in open(outfile).read().split()]
    hw = [int(x, 16) for x in open(f'{d}/hw_s_ntt.txt').read().split()]
    assert len(oracle) == n and len(hw) == n, 'length mismatch'

    mism = sum(1 for a, b in zip(oracle, hw) if a != b)
    for i, (a, b) in enumerate(zip(oracle, hw)):
        if a != b and i < 8:
            print(f'  s_ntt[{i}]: hw={b:x} oracle={a:x}')
    print(f'keygen NTT cross-check: {mism}/{n} mismatches -> '
          f'{"PASS" if mism == 0 else "FAIL"}')
    sys.exit(0 if mism == 0 else 1)


if __name__ == '__main__':
    main()
