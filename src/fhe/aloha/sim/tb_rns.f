// Rung 3: tb_RNS (FP->RNS mapping; wraps UnifiedTransformation + sampling banks + FFTTw_RNS_ROM).
-f $ALOHA_PORT/sim/aloha_prim_trivium.f
-f $ALOHA_PORT/sim/aloha_engine.f
$ALOHA_SRC/Aloha-HE_Common/Testbench/tb_RNS.sv
