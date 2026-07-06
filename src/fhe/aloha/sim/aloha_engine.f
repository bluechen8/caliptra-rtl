// Shared Rung-3 engine filelist: incdir + behavioral macro models + the
// full Aloha-HE FFT/NTT datapath. Included via -f by tb_{unifiedtransformation,pwm,rns}.f.
+incdir+$ALOHA_SRC/Aloha-HE_Common
$ALOHA_SRC/Aloha-HE_Common/CommonDefinitions.vh
$ALOHA_PORT/rtl/aloha_dsp_behav.sv
$ALOHA_PORT/rtl/aloha_bram_behav.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/BitReverse.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/CarrySaveAdder.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/DelayRegisterReset.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/DelayRegister.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/Expand.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/HammingWeight.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/LeadingZeroCount.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/Project.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/INTTScale.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/ModAdd.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/ModMul.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/ModSub.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/MontRed_Stage.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/MontRed.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/NTTButterfly.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/PWM.sv
$ALOHA_PORT/rtl/PWMSk.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/RNSErrorPolys.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/RNS.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/ComplexMultiplier.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FFTButterflyAddStage.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FFTButterfly.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FFTTwFctStorage.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FLPAdderDenormalization.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FLPAdderSigAddNormalize.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FLPAdder.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/FLPMultiplier.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/IntToFlP.sv
$ALOHA_SRC/Aloha-HE_Common/FloatingPoint/IntToFlPWrapper.sv
// C'-2: sampler PRNG is now caliptra_prim_trivium (see aloha_prim_trivium.f,
// listed by the standalone tops; in the SoC build it comes from the base .vf).
// Trivium64.v is retired.
$ALOHA_SRC/Aloha-HE_Common/RandomSampling/RandomSampling.sv
$ALOHA_SRC/Aloha-HE_Common/RandomSampling/TriviumAdapter.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/IntMultiplier_24x34.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/IntMultiplier_54x54.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/IntMultPool.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/SharedFFTBrams.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/UnifiedLoadLogic.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/UnifiedStoreLogic.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/UnifiedTransformation.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/UnifiedTwFctGen.sv
