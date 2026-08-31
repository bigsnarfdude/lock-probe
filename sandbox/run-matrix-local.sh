#!/usr/bin/env bash
# Sibling of run-matrix.sh for a LOCAL llama-server (GH200 lane). Same loop, but the endpoint,
# model tag, quant, effort, concurrency and per-arm timeout come from env instead of being
# hardcoded for Ollama cloud. Runs INSIDE the sandbox with --network host.
set -uo pipefail
grep -q "$(hostname)" /etc/hosts 2>/dev/null || echo "127.0.0.1 $(hostname)" >> /etc/hosts
EP=${EP:-http://127.0.0.1:8001/v1/chat/completions}
N=${N:-15}
MODELS=${MODELS:-"q38-flash-next"}          # server alias, sent as "model"
MODEL_TAG=${MODEL_TAG:-qwen3.8-flash-next}  # what the JSON/MATRIX row is called
QUANT=${QUANT:-UD-Q4_K_XL}
EFFORT=${EFFORT:-}                          # "" = model default (xhigh on Flash-Next); low|medium|xhigh
CONC=${CONC:-4}
MAXTOK=${MAXTOK:-16384}
ARM_TIMEOUT=${ARM_TIMEOUT:-14400}
CONDS=${CONDS:-"neutral PC PXR conceal L4C"}
OUT=/out; mkdir -p "$OUT"
san(){ echo "$1" | tr '/:. ' '____'; }
echo "endpoint=$EP  N=$N  effort='${EFFORT}'  conc=$CONC  quant=$QUANT"
echo "models: $MODELS (tag $MODEL_TAG)"
echo "conds:  $CONDS"
for M in $MODELS; do
  TAG=$(san "$MODEL_TAG"); [ -n "$EFFORT" ] && TAG="${TAG}_${EFFORT}"
  for C in $CONDS; do
    ARM="${TAG}__${C}"; F="$OUT/${ARM}.json"
    [ -s "$F" ] && { echo "skip $ARM"; continue; }
    echo; echo "==== $M / $C  n=$N (effort '${EFFORT:-default}') ===="
    timeout "$ARM_TIMEOUT" python3 /probe/lib/smoke_eval.py --arm "$ARM" --endpoint "$EP" \
      --model-name "$M" --model-tag "$TAG" --quant "$QUANT" \
      --trials "$N" --concurrency "$CONC" --agent-user agent \
      --cond "$C" --reasoning-effort "$EFFORT" --max-tokens "$MAXTOK" --out "$F" 2>&1 | tail -12
  done
done
echo; echo "==== SHAPE MATRIX ===="
python3 /probe/lib/analyze_matrix.py "$OUT" | tee "$OUT/MATRIX.txt"
