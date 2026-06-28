#!/usr/bin/env python3
# Aloha-HE FFT oracle (numpy): the merged-datapath FFT is a standard transform —
# xout[k] = exp(-i*pi*k/N) * DFT(bitrev(xin))[k]  (bit-reversed-input DFT + negacyclic
# post-twiddle). Reproduces shipped fft_out/fft_stored_out to relErr ~6e-14.
import sys, struct, numpy as np
def b2d(h): return struct.unpack('<d',struct.pack('<Q',int(h,16)))[0]
def d2h(x): return f"{struct.unpack('<Q',struct.pack('<d',x))[0]:016x}"
def brev(a):
    n=len(a); lg=int(np.log2(n))
    return a[[int(format(i,f'0{lg}b')[::-1],2) for i in range(n)]]
def aloha_fft(xin):
    N=len(xin); k=np.arange(N)
    return np.exp(-1j*np.pi*k/N)*np.fft.fft(brev(xin))
def rd(fn):
    o=[]
    for l in open(fn):
        f=l.split()
        if len(f)==2: o.append(complex(b2d(f[0]),b2d(f[1])))
    return np.array(o)
def wr(fn,a):
    with open(fn,"w") as f:
        for z in a: f.write(f"{d2h(z.real)} {d2h(z.imag)}\n")
if __name__=="__main__":
    cmd=sys.argv[1]
    if cmd=="validate":     # validate vs shipped @ given dir
        d=sys.argv[2]; xin=rd(f"{d}/fft_in.txt"); xo=rd(f"{d}/fft_out.txt")
        c=aloha_fft(xin); print("relErr vs shipped fft_out:", np.max(np.abs(c-xo))/np.max(np.abs(xo)))
    elif cmd=="gen":        # gen <LOGN> <outdir> : random input + golden, for both fft_ and fft_stored_ files
        N=1<<int(sys.argv[2]); out=sys.argv[3]
        import os; os.makedirs(out,exist_ok=True)
        rng=np.random.default_rng(1234)
        xin=(rng.standard_normal(N)+1j*rng.standard_normal(N))*10
        xo=aloha_fft(xin)
        for tag in ("","_stored"):
            wr(f"{out}/fft{tag}_in.txt", xin); wr(f"{out}/fft{tag}_out.txt", xo)
        print(f"wrote N={N} fft tv (both on-the-fly + stored) to {out}")
