MASK=(1<<64)-1
def cat(rA,kA,rB,kB):  # {rA[kA:0], rB[63:kB]}  -> rA low (kA+1) bits as high, rB>>kB as low(63-kB+1)
    hi = rA & ((1<<(kA+1))-1)
    lo = rB >> kB
    return ((hi << (64-(kB))) | lo) & MASK
class Trivium64:
    def __init__(self, seed):
        self.s11=seed & MASK; self.s12=0; self.s21=0; self.s22=0; self.s31=0
        self.s32=0x0000700000000000
    def _taps(self):
        s=self
        s66 =cat(s.s12,1,s.s11,2);   s93 =cat(s.s12,28,s.s11,29)
        s162=cat(s.s22,4,s.s21,5);   s177=cat(s.s22,19,s.s21,20)
        s243=cat(s.s32,1,s.s31,2);   s288=cat(s.s32,46,s.s31,47)
        s91 =cat(s.s12,26,s.s11,27); s92 =cat(s.s12,27,s.s11,28)
        s171=cat(s.s22,13,s.s21,14); s175=cat(s.s22,17,s.s21,18); s176=cat(s.s22,18,s.s21,19)
        s264=cat(s.s32,22,s.s31,23); s286=cat(s.s32,44,s.s31,45); s287=cat(s.s32,45,s.s31,46)
        s69 =cat(s.s12,4,s.s11,5)
        t1=s66^s93; t2=s162^s177; t3=s243^s288
        t1n=(t1^(s91&s92)^s171)&MASK; t2n=(t2^(s175&s176)^s264)&MASK; t3n=(t3^(s286&s287)^s69)&MASK
        tout=(t1^t2^t3)&MASK
        return t1n,t2n,t3n,tout
    def step(self):  # returns tout (combinational from current state), then advances
        t1n,t2n,t3n,tout=self._taps()
        self.s11,self.s12,self.s21,self.s22,self.s31,self.s32 = t3n,self.s11,t1n,self.s21,t2n,self.s31
        return tout
def cbd(w):
    pos=bin(w & ((1<<21)-1)).count('1'); neg=bin((w>>21)&((1<<21)-1)).count('1')
    d=pos-neg
    return (0x20|(-d))&0x3f if d<0 else d&0x3f
