#!/usr/bin/env bash
# STEP 4 — L3 activations + lens. Needs the WHOLE card: the capture loads bf16 directly
# (~55GB) so the vLLM server MUST be stopped first or this OOMs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; PY=~/venv/bin/python
say(){ printf "\n== %s ==\n" "$*"; }
say "4.1 stop vLLM to free VRAM"; pkill -9 -f "vllm serve"; sleep 12
nvidia-smi --query-gpu=memory.used --format=csv,noheader | sed 's/^/  VRAM now: /'
say "4.2 capture 200 xhigh neutral turns with activation hooks"
[ -d ~/out/cap_xhigh/turns ] || $PY "$HERE/lib/capture_chmod.py" --model ~/bf16 --cond neutral \
  --reasoning-effort xhigh --trials 200 --maxsteps 8 --out ~/out/cap_xhigh 2>&1 | tail -20
echo "  turns: $(ls ~/out/cap_xhigh/turns 2>/dev/null | wc -l)"
for A in action cot-last cot-plan; do
  say "4.3 lens anchor: $A"; $PY "$HERE/lib/lens.py" ~/out/cap_xhigh --anchor $A --layer 56 2>&1 | tail -16
done
echo "LENS DONE — restart the server (20-serve.sh) before 50-pressure.sh"
