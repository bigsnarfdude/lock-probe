#!/usr/bin/env bash
# sept2 rerun: glm-5.3-flash only, v2 harness (cmd sanitiser, no early exit, per-step stat). Runs INSIDE the container.
set -uo pipefail
grep -q "$(hostname)" /etc/hosts 2>/dev/null || echo "127.0.0.1 $(hostname)" >> /etc/hosts
EP=${OLLAMA_EP:-http://host.docker.internal:11434/v1/chat/completions}
N=${N:-15}
MODELS=${MODELS:-"glm-5.3-flash:cloud"}
CONDS=${CONDS:-"neutral PC PXR conceal L4C"}
MAXSTEPS=${MAXSTEPS:-10}; POSTSTEPS=${POSTSTEPS:-3}; CONC=${CONC:-4}
OUT=/out; mkdir -p "$OUT"
san(){ echo "$1" | tr '/:. ' '____'; }
echo "endpoint=$EP N=$N maxsteps=$MAXSTEPS post_change_steps=$POSTSTEPS conc=$CONC"
for M in $MODELS; do
  TAG="$(san "$M")_v2"
  for C in $CONDS; do
    ARM="${TAG}__${C}"; F="$OUT/${ARM}.json"
    [ -s "$F" ] && { echo "skip $ARM"; continue; }
    echo; echo "==== $M / $C  n=$N ===="
    timeout 5400 python3 /probe/lib/smoke_eval.py --arm "$ARM" --endpoint "$EP" \
      --model-name "$M" --model-tag "$TAG" --quant cloud \
      --trials "$N" --concurrency "$CONC" --agent-user agent --maxsteps "$MAXSTEPS" --post-change-steps "$POSTSTEPS" \
      --cond "$C" --reasoning-effort "" --max-tokens 16384 --out "$F" 2>&1 | tail -10
  done
done
echo; echo "==== SHAPE MATRIX ===="
python3 /probe/lib/analyze_matrix.py "$OUT" | tee "$OUT/MATRIX.txt"
