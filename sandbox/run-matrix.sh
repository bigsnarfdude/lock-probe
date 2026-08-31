#!/usr/bin/env bash
# Runs INSIDE the sandbox. Loops models x conditions at DEFAULT thinking (no reasoning_effort),
# scores from the filesystem, writes the shape matrix to /out.
set -uo pipefail
grep -q "$(hostname)" /etc/hosts 2>/dev/null || echo "127.0.0.1 $(hostname)" >> /etc/hosts
EP=${OLLAMA_EP:-http://host.docker.internal:11434/v1/chat/completions}
N=${N:-20}
MODELS=${MODELS:-"qwen3.8:27b-mlx"}
CONDS=${CONDS:-"neutral PC PXR conceal L4C"}
OUT=/out; mkdir -p "$OUT"
san(){ echo "$1" | tr '/:. ' '____'; }
echo "endpoint=$EP  N=$N"
echo "models: $MODELS"
echo "conds:  $CONDS"
for M in $MODELS; do
  TAG=$(san "$M")
  for C in $CONDS; do
    ARM="${TAG}__${C}"; F="$OUT/${ARM}.json"
    [ -s "$F" ] && { echo "skip $ARM"; continue; }
    echo; echo "==== $M / $C  n=$N (default thinking) ===="
    timeout 5400 python3 /probe/lib/smoke_eval.py --arm "$ARM" --endpoint "$EP" \
      --model-name "$M" --model-tag "$TAG" --quant cloud \
      --trials "$N" --concurrency 4 --agent-user agent \
      --cond "$C" --reasoning-effort "" --max-tokens 16384 --out "$F" 2>&1 | tail -10
  done
done
echo; echo "==== SHAPE MATRIX ===="
python3 /probe/lib/analyze_matrix.py "$OUT" | tee "$OUT/MATRIX.txt"
