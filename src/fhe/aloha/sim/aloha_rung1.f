// Rung 1 file list: tb_ModMul (self-checking modular-multiply TB).
// Unmodified Aloha-HE leaf RTL is referenced in place from $ALOHA_SRC
// (the working checkout); only the DSP black boxes are replaced by our
// latency-accurate behavioral models in rtl/aloha_dsp_behav.sv.
//
// $ALOHA_SRC defaults to the vendored submodule ($ALOHA_PORT/vendor; set by run_tb.sh).
// $ALOHA_PORT is this aloha/ dir.

// CommonDefinitions.vh must be processed first: it defines `KEEP_HIERARCHY,
// referenced by the (* keep_hierarchy = ... *) attributes in the leaf RTL.
+incdir+$ALOHA_SRC/Aloha-HE_Common
$ALOHA_SRC/Aloha-HE_Common/CommonDefinitions.vh

// --- our technology-generic DSP replacements (the only swapped pieces) ---
$ALOHA_PORT/rtl/aloha_dsp_behav.sv

// --- unmodified Aloha-HE leaf RTL ---
$ALOHA_SRC/Aloha-HE_Common/Utils/DelayRegister.sv
$ALOHA_SRC/Aloha-HE_Common/Utils/CarrySaveAdder.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/IntMultiplier_24x34.sv
$ALOHA_SRC/Aloha-HE_Common/SharedArithmetics/IntMultiplier_54x54.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/MontRed_Stage.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/MontRed.sv
$ALOHA_SRC/Aloha-HE_Common/ModRing/ModMul.sv

// --- self-checking testbench (top) ---
$ALOHA_SRC/Aloha-HE_Common/Testbench/tb_ModMul.sv
