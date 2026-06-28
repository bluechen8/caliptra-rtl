#!/usr/bin/env python3
# Real golden generator for the RNS engine. RNS reduces the encode FFT's
# double-precision coefficients (and the sampled errors) mod each Solinas prime q
# -- and folds in the encrypt error e0. It COMPUTES the golden from the inputs and
# at N=8192 reproduces the shipped golden bit-for-bit (use `validate`).
#
#   python3 gen_rns.py validate <shipped_tv_dir>
#   python3 gen_rns.py gen <LOGN> <shipped_tv_dir> <out_dir>
#
# Maps (q = Solinas prime; RNS headers carry the ALREADY-negated 17-bit qm):
#   message c0[i] = ( float_to_int(double[i]) + e0[i] ) mod q          # encrypt: round(Δ·m)+e0
#   e1[i]         = signed6(e1_sample[i]) mod q
#   v[i]          = ternary(v_sample[i])  mod q
# float_to_int reproduces RNS.sv: significand {1,mant[51:0]} shifted by
# e=(raw_exp+scale) mod 2^12 (signed); e>=0 -> <<e, e<0 -> round(sig >> (-e-1)>>1); negate if sign.
import sys, os, struct, random

def b2d(h): return struct.unpack('<d', struct.pack('<Q', int(h, 16)))[0]
def d2h(x): return f"{struct.unpack('<Q', struct.pack('<d', x))[0]:016x}"
def q_from(k, qm_neg):                 # qm_neg = the (already-negated) 17-bit qm in the RNS header
    return ((0x1fff >> (8 - k)) & 0x1fff) << 41 | (qm_neg << 24) | 1

def float_to_int(bits, scale, q):
    sig = (1 << 52) | (bits & ((1 << 52) - 1)); exp = (bits >> 52) & 0x7ff; sign = (bits >> 63) & 1
    e = (exp + scale) & 0xfff           # 12-bit, interpreted signed via bit 11
    if e >> 11:                          # negative: round(sig >> (-e-1) >> 1)
        rsh = (~e) & 0xfff               # -e-1 in 12 bits
        v = sig >> rsh; v = (v >> 1) + (v & 1)
    else:
        v = sig << e
    mag = v % q
    return (q - mag) % q if (sign and mag) else mag
def e_val(e6, q):  return (e6 & 0x1f) if (e6 >> 5) == 0 else q - (e6 & 0x1f)   # 6-bit sign-magnitude
def v_val(t, q):   return {0: 0, 1: 1, 2: 2, 3: q - 1}[t]                       # 2-bit ternary (3 = -1)

def hdr_blocks(path, nf):              # -> [(header_fields, [data_fields,...])]
    out = []; cur = None
    for l in open(path):
        f = l.split()
        if not f: continue
        if len(f) == nf: cur = (f, []); out.append(cur)
        else: cur[1].append(f)
    return out
def read_samples(path):               # error_polys_sam: one packed 14-bit word per line
    s = [int(x, 16) for x in open(path).read().split()]
    return [(w >> 6) & 0x3f for w in s], [w & 0x3f for w in s], [(w >> 12) & 0x3 for w in s]  # e0,e1,v

def validate(ship):
    e0, e1, v = read_samples(f"{ship}/error_polys_sam.txt")
    dbl = hdr_blocks(f"{ship}/double_rns_testvec.txt", 7)
    err = [l.split() for l in open(f"{ship}/error_rns_testvec.txt") if l.strip()]
    qs = [q_from(int(h[0], 16) - 46, int(h[1], 16)) for h, _ in dbl]
    bm = be1 = bv = tot = 0
    N = len(dbl[0][1])
    for b, (h, data) in enumerate(dbl):
        q = qs[b]; sc = int(h[2], 16)
        for i, (din, dout) in enumerate(data):
            if (float_to_int(int(din, 16), sc, q) + e_val(e0[i], q)) % q != int(dout, 16): bm += 1
            if e_val(e1[i], q) != int(err[b * N + i][1], 16): be1 += 1
            if v_val(v[i], q) != int(err[b * N + i][0], 16): bv += 1
            tot += 1
    ok = bm == 0 and be1 == 0 and bv == 0
    print(f"RNS @N=8192: message {bm}/{tot}, e1 {be1}/{tot}, v {bv}/{tot} -> {'PASS' if ok else 'FAIL'}")

def gen(logn, ship, out):
    N = 1 << logn; os.makedirs(out, exist_ok=True)
    rng = random.Random(1234)
    dbl = hdr_blocks(f"{ship}/double_rns_testvec.txt", 7)   # reuse the modulus/scale headers
    qs = [q_from(int(h[0], 16) - 46, int(h[1], 16)) for h, _ in dbl]
    # fresh random error samples (any valid sample is reduced the same way)
    e0 = [rng.randrange(64) for _ in range(N)]; e1 = [rng.randrange(64) for _ in range(N)]
    v  = [rng.choice((0, 1, 3)) for _ in range(N)]
    with open(f"{out}/error_polys_sam.txt", "w") as f:
        for i in range(N): f.write(f"{(v[i] << 12) | (e0[i] << 6) | e1[i]:x}\n")
    with open(f"{out}/double_rns_testvec.txt", "w") as fd, open(f"{out}/error_rns_testvec.txt", "w") as fe:
        for b, (h, _) in enumerate(dbl):
            q = qs[b]; sc = int(h[2], 16)
            sc_s = sc - 4096 if sc >= 2048 else sc
            # The float->int datapath only supports e_unbiased = exp+scale up to ~159
            # (4 x 40-bit chunks); constrain exp so e_unbiased <= 100 (negative is fine).
            exp_hi = max(1, min(0x7fe, 100 - sc_s))
            fd.write(" ".join(h) + "\n")                     # keep header verbatim (incl. the 4 metadata words)
            for i in range(N):
                bits = rng.randrange(0, exp_hi + 1) << 52 | rng.getrandbits(52) | (rng.getrandbits(1) << 63)
                fd.write(f"{bits:x} {(float_to_int(bits, sc, q) + e_val(e0[i], q)) % q:x}\n")
                fe.write(f"{v_val(v[i], q):x} {e_val(e1[i], q):x}\n")
    print(f"generated RNS goldens (message + e1/v) for N={N} in {out}")

if __name__ == "__main__":
    if sys.argv[1] == "validate": validate(sys.argv[2])
    elif sys.argv[1] == "gen":    gen(int(sys.argv[2]), sys.argv[3], sys.argv[4])
