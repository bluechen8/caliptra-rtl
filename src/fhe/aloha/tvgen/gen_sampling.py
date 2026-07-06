#!/usr/bin/env python3
# Aloha-HE sampler oracle (Trivium + CBD/ternary/uniform). CBD/ternary/uniform
# post-processing is bit-exact vs RandomSampling.sv and was validated against the
# shipped N=8192 vectors under the old Trivium64.
#
# C'-2: the sampler PRNG is now caliptra_prim_trivium (SeedTypeKeyIv), so the
# keystream -- and therefore the expected e0/e1/v/pk1 vectors -- are regenerated
# from the CaliptraPrimTrivium SW model. The 18-update (1152-bit) KeyIv warmup is
# baked into CaliptraPrimTrivium.__init__, so the first .step() word is already
# post-warmup => OFF=0 (no extra discard, unlike the old Trivium64 OFF=18 path).
import sys
from trivium import CaliptraPrimTrivium, cbd
OFF=0  # warmup baked into CaliptraPrimTrivium.__init__ (KeyIv auto-warmup)
def tern(w):
    b=(w>>48)&0xffff
    return None if b==0xffff else (0 if b<0x5555 else (1 if b<0xaaaa else 3))
def words(seed,n):
    t=CaliptraPrimTrivium(seed); return [t.step() for _ in range(n)]
def gen_error(seeds,N,out):
    with open(out,"w") as f:
        for seed in seeds:
            W=words(seed,OFF+2*N+2000)
            e0=[cbd(W[OFF+i]) for i in range(N)]; e1=[cbd(W[OFF+N+i]) for i in range(N)]
            v=[]; c=OFF
            while len(v)<N:
                tv=tern(W[c]); c+=1
                if tv is not None: v.append(tv)
            f.write(f"{seed:x}\n")
            for i in range(N): f.write(f"{e0[i]:x} {e1[i]:x} {v[i]:x}\n")
def gen_key(hdrs,N,out,LOGQ=54):
    with open(out,"w") as f:
        for seed,ck,qm_raw in hdrs:
            qm=(-qm_raw)&((1<<17)-1); top=(0x1fff>>(8-ck))&0x1fff; q=(top<<41)|(qm<<24)|1
            shift=8-ck; W=words(seed,OFF+4*N+4000); pk1=[]; c=OFF
            while len(pk1)<N and c<len(W):
                samp=(W[c]&((1<<LOGQ)-1))>>shift; c+=1
                if samp<q: pk1.append(samp)
            f.write(f"{seed:x} {ck:x} {qm_raw:x}\n")
            for i in range(N): f.write(f"{pk1[i]:x}\n")
def read_err_seeds(p):
    seeds=[]; 
    for l in open(p):
        f=l.split()
        if len(f)==1: seeds.append(int(f[0],16))
    return seeds
def read_key_hdrs(p):
    h=[]
    for l in open(p):
        f=l.split()
        if len(f)==3: h.append((int(f[0],16),int(f[1],16),int(f[2],16)))
    return h
if __name__=="__main__":
    # arg1 = LOGN (consistent with gen_fft.py / main.go / Generate*ROM.py), arg2 = shipped-tv dir, arg3 = out dir
    N=1<<int(sys.argv[1]); SHIP=sys.argv[2]; OUT=sys.argv[3]
    import os; os.makedirs(OUT,exist_ok=True)
    gen_error(read_err_seeds(f"{SHIP}/error_sampling.txt"),N,f"{OUT}/error_sampling.txt")
    gen_key(read_key_hdrs(f"{SHIP}/key_sampling.txt"),N,f"{OUT}/key_sampling.txt")
    print(f"wrote N={N} sampling tv to {OUT}")
