#!/bin/bash
# L3 capture (needs the whole card, no server) -> then the gzip negative control (needs vLLM).
set -uo pipefail
cd ~/chmod444-probe
say(){ printf "\n== [%s] %s ==\n" "$(date +%T)" "$*"; }
freegpu(){ for p in $(nvidia-smi --query-compute-apps=pid --format=csv,noheader); do sudo kill -9 $p 2>/dev/null; done
           pkill -9 -f vllm 2>/dev/null; sleep 15
           echo "  VRAM: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"; }

say "free the card (pkill by NAME misses EngineCore workers -- kill by GPU pid)"
freegpu

say "L3: capture 200 xhigh turns with activation hooks"
~/venv/bin/python lib/capture_chmod.py --model ~/bf16 --cond neutral \
  --reasoning-effort xhigh --trials 200 --maxsteps 8 --out out/cap_xhigh 2>&1 | tail -20
echo "  turns: $(ls out/cap_xhigh/turns 2>/dev/null | wc -l)"

for A in action cot-last cot-plan; do
  say "L3 lens anchor: $A"
  ~/venv/bin/python lib/lens.py out/cap_xhigh --anchor $A --layer 56 2>&1 | tail -16
done

say "free the card again for vLLM"
freegpu
say "serve for the negative control"
setsid nohup ~/venv/bin/vllm serve ~/bf16 --served-model-name local --port 8000 \
  --max-num-seqs 64 --gdn-prefill-backend triton > out/srv2.log 2>&1 < /dev/null &
for i in $(seq 1 120); do curl -fsS http://127.0.0.1:8000/v1/models >/dev/null 2>&1 && break; sleep 5; done
curl -fsS http://127.0.0.1:8000/v1/models >/dev/null 2>&1 || { echo "FATAL server"; exit 1; }

EP=http://127.0.0.1:8000/v1/chat/completions
for E in low medium xhigh; do
  F=out/gzip_${E}.json; [ -s "$F" ] && { echo "skip $E"; continue; }
  say "GZIP negative control / $E  n=100"
  ~/venv/bin/python lib/smoke_eval.py --arm gzip_${E} --endpoint $EP --model-tag Qwen/Qwen3.8-27B \
    --quant bf16 --trials 100 --concurrency 8 --agent-user agent \
    --cond gzip --reasoning-effort $E --out $F 2>&1 | tee out/log_gzip_${E}.txt | tail -16
done
say "ALL DONE"
