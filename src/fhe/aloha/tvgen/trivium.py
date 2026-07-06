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

# ---------------------------------------------------------------------------
# C'-2: bit-exact SW model of caliptra_prim_trivium (SeedTypeKeyIv, OutputWidth
# 64), mirroring caliptra_prim_trivium_pkg::{trivium_seed_key_iv,
# trivium_update_state, trivium_generate_key_stream}. This is the SAME eSTREAM
# Trivium cipher as Trivium64 above, but with the OpenTitan/Caliptra flat
# 288-bit state + key/IV seed mapping, so the keystream differs bit-for-bit ->
# the sampling goldens are regenerated from THIS model (see gen_sampling.py).
#
# TriviumAdapter.sv maps the 64-bit Aloha seed to the Trivium key (low 64 of 80,
# iv=0). SeedTypeKeyIv performs 1152/64 = 18 automatic init updates before the
# keystream is usable; we bake those into __init__ so .step() returns the first
# post-warmup word (matching the RTL adapter's random_valid alignment).
class CaliptraPrimTrivium:
    NINIT=18  # (StateWidth*4)/OutputWidth = 1152/64 KeyIv init updates
    def __init__(self, seed, iv=0):
        key=seed & ((1<<80)-1)
        # state = {3'b111, 112'b0, iv[79:0], 13'b0, key[79:0]}
        st=(0b111<<285) | ((iv & ((1<<80)-1))<<93) | key
        for _ in range(self.NINIT):
            st=self._update64(st)
        self.state=st
    @staticmethod
    def _b(s,i): return (s>>i)&1
    @classmethod
    def _update1(cls,s):
        # Returns (keystream_bit(s), next_state). The output bit is exactly the
        # three tap-sums the state update already needs, so compute them once.
        b=cls._b
        add_65_92  =b(s,65) ^b(s,92)
        add_161_176=b(s,161)^b(s,176)
        add_242_287=b(s,242)^b(s,287)
        out_bit=add_65_92 ^ add_161_176 ^ add_242_287
        mul_90_91  =b(s,90) &b(s,91)
        mul_174_175=b(s,174)&b(s,175)
        mul_285_286=b(s,285)&b(s,286)
        out0  =b(s,68) ^(mul_285_286^add_242_287)
        out93 =b(s,170)^(add_65_92  ^mul_90_91)
        out177=b(s,263)^(mul_174_175^add_161_176)
        low =  s        & ((1<<92)-1)   # in[91:0]   -> out[92:1]
        mid = (s>>93)   & ((1<<83)-1)   # in[175:93] -> out[176:94]
        high= (s>>177)  & ((1<<110)-1)  # in[286:177]-> out[287:178]
        return out_bit, (out0 | (low<<1) | (out93<<93) | (mid<<94) | (out177<<177) | (high<<178))
    @classmethod
    def _update64(cls,s):
        for _ in range(64): _,s=cls._update1(s)
        return s
    def step(self):
        s=self.state; w=0
        for i in range(64):
            bit,s=self._update1(s)
            w|=bit<<i
        self.state=s
        return w
