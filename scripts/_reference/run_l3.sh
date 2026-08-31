#!/bin/bash
# L3 only. vLLM holds ~73GB; the capture loads bf16 directly with transformers and needs
# ~54GB, so the server MUST be stopped first or this OOMs.
set -uo pipefail
cd ~/chmod444-probe
say(){ printf "\n== [%s] %s ==\n" "$(date +%T)" "$*"; }

say "stopping vLLM to free VRAM"
pkill -9 -f "vllm serve"; sleep 12
nvidia-smi --query-gpu=memory.used --format=csv,noheader | sed "s/^/  VRAM now: /"

say "capture xhigh with activation hooks (n=200)"
~/venv/bin/python lib/capture_chmod.py --model ~/bf16 --cond neutral \
   --reasoning-effort xhigh --trials 200 --maxsteps 8 \
   --out out/cap_xhigh 2>&1 | tail -25
echo "  turns captured: $(ls out/cap_xhigh/turns 2>/dev/null | wc -l)"

for A in action cot-last cot-plan; do
  say "lens anchor: $A"
  ~/venv/bin/python lib/lens.py out/cap_xhigh --anchor $A --layer 56 2>&1 | tail -18
done
say "L3 DONE"
