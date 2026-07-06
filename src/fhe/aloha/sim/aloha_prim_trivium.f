// C'-2 step 1: the audited Caliptra/OpenTitan Trivium primitive used by the
// Aloha sampler (RandomSampling -> TriviumAdapter -> caliptra_prim_trivium),
// replacing the vendored Trivium64.v.
//
// These sources are ONLY listed for the standalone Aloha Verilator builds (the
// engine/round-trip/sampling TBs). In the full-SoC build they are already
// compiled by the base caliptra_top_tb.vf (AES/SHA3 use the same primitive), so
// the SoC filelist (caliptra_top_tb_fhe.vf) must NOT `-f` this file.
//
// Paths are $ALOHA_PORT-relative (= src/fhe/aloha) because the standalone
// run_tb.sh only exports ALOHA_PORT/ALOHA_SRC (no CALIPTRA_ROOT).
+incdir+$ALOHA_PORT/../../../src/caliptra_prim/rtl
+incdir+$ALOHA_PORT/../../../src/libs/rtl
$ALOHA_PORT/../../../src/caliptra_prim/rtl/caliptra_prim_util_pkg.sv
$ALOHA_PORT/../../../src/caliptra_prim/rtl/caliptra_prim_trivium_pkg.sv
$ALOHA_PORT/../../../src/caliptra_prim/rtl/caliptra_prim_trivium.sv
