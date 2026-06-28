#!/usr/bin/env python3
# Real golden generators for the per-coefficient engines IntToFlp and PWM:
# they COMPUTE the golden from the input (not truncate the shipped one), and at
# N=8192 reproduce the shipped golden bit-for-bit when fed the shipped inputs
# (use `validate` to check that). Both transforms are pointwise, so small-N goldens
# are just the same transform over fresh inputs.
#
#   python3 gen_pointwise.py validate <shipped_tv_dir>          # reproduce shipped goldens @ N=8192
#   python3 gen_pointwise.py gen <LOGN> <shipped_tv_dir> <out>  # emit N=2^LOGN goldens (random inputs)
#
# Transforms (both mod the Solinas prime q built from the per-block header):
#   IntToFlp : double = signed_center(int, q) * 2^scale         (scale is signed)
#   PWM      : result = MontMul(a,b) + c  mod q  (= a*b*R^-1 + c, R = 2^72)
import sys, os, struct, random

R = 1 << 72

def q_from(k, qm_neg):
    # q = {(0x1fff >> (8-k)), qm, 0^23, 1}; the RNS/IntToFlp/PWM headers carry the
    # raw qm and the TB negates it, so callers pass the already-negated 17-bit qm.
    top = (0x1fff >> (8 - k)) & 0x1fff
    return (top << 41) | (qm_neg << 24) | 1

def d2h(x): return f"{struct.unpack('<Q', struct.pack('<d', x))[0]:016x}"
def b2d(h): return struct.unpack('<d', struct.pack('<Q', int(h, 16)))[0]
def signed(x, q): return x - q if x > q // 2 else x

def read_blocks(path, hdr_nfields):
    # -> list of (header_fields[], [data_line_fields[], ...])
    blocks = []; cur = None
    for l in open(path):
        f = l.split()
        if not f: continue
        if len(f) == hdr_nfields:
            cur = (f, []); blocks.append(cur)
        else:
            cur[1].append(f)
    return blocks

# ---- IntToFlp: header "current_k qm scale"; data "<int> <double>" ----
def intoflp_out(xint, k, qm_raw, scale):
    q = q_from(k, (-qm_raw) & ((1 << 17) - 1))
    s = scale - (1 << 32) if scale >= (1 << 31) else scale
    v = float(signed(xint, q))
    return v / float(1 << (-s)) if s < 0 else v * float(1 << s)

def intoflp_validate(ship):
    bad = tot = 0
    for hdr, data in read_blocks(f"{ship}/int_to_double_wrap_testvec.txt", 3):
        k, qm, sc = (int(x, 16) for x in hdr)
        for xi_h, exp_h in data:
            if d2h(intoflp_out(int(xi_h, 16), k, qm, sc)) != exp_h.zfill(16)[-16:] and \
               struct.pack('<d', intoflp_out(int(xi_h, 16), k, qm, sc)) != struct.pack('<d', b2d(exp_h)):
                bad += 1
            tot += 1
    return bad, tot

def intoflp_gen(ship, N, out, rng):
    with open(out, "w") as o:
        for hdr, _ in read_blocks(f"{ship}/int_to_double_wrap_testvec.txt", 3):
            k, qm, sc = (int(x, 16) for x in hdr)
            q = q_from(k, (-qm) & ((1 << 17) - 1))
            o.write(f"{k:x} {qm:x} {sc:x}\n")
            for _ in range(N):
                xi = rng.randrange(q)
                o.write(f"{xi:x} {d2h(intoflp_out(xi, k, qm, sc))}\n")

# ---- PWM: header "current_k qm"; data "<a> <b> <c> <result>" ----
def pwm_out(a, b, c, q, Rinv): return (a * b * Rinv + c) % q

def pwm_validate(ship):
    bad = tot = 0
    for hdr, data in read_blocks(f"{ship}/PWM.txt", 2):
        k, qm = (int(x, 16) for x in hdr)
        q = q_from(k, (-qm) & ((1 << 17) - 1)); Rinv = pow(R, -1, q)
        for a, b, c, r in data:
            if pwm_out(int(a, 16), int(b, 16), int(c, 16), q, Rinv) != int(r, 16): bad += 1
            tot += 1
    return bad, tot

def pwm_gen(ship, N, out, rng):
    with open(out, "w") as o:
        for hdr, _ in read_blocks(f"{ship}/PWM.txt", 2):
            k, qm = (int(x, 16) for x in hdr)
            q = q_from(k, (-qm) & ((1 << 17) - 1)); Rinv = pow(R, -1, q)
            o.write(f"{k:x} {qm:x}\n")
            for _ in range(N):
                a, b, c = rng.randrange(q), rng.randrange(q), rng.randrange(q)
                o.write(f"{a:x} {b:x} {c:x} {pwm_out(a, b, c, q, Rinv):x}\n")

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "validate":
        ship = sys.argv[2]
        for name, fn in (("IntToFlp", intoflp_validate), ("PWM", pwm_validate)):
            bad, tot = fn(ship); print(f"{name}: {bad}/{tot} mismatches @N=8192 -> {'PASS' if bad == 0 else 'FAIL'}")
    elif cmd == "gen":
        LOGN = int(sys.argv[2]); ship = sys.argv[3]; out = sys.argv[4]; N = 1 << LOGN
        os.makedirs(out, exist_ok=True)
        rng = random.Random(1234)
        intoflp_gen(ship, N, f"{out}/int_to_double_wrap_testvec.txt", rng)
        pwm_gen(ship, N, f"{out}/PWM.txt", rng)
        print(f"generated IntToFlp + PWM goldens for N={N} in {out}")
