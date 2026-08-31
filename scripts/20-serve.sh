#!/usr/bin/env bash
# STEP 2 — serve bf16 with vLLM. reasoning_effort is PER-REQUEST, never pinned on the server.
set -uo pipefail
say(){ printf "\n== %s ==\n" "$*"; }
freegpu(){ for p in $(nvidia-smi --query-compute-apps=pid --format=csv,noheader); do sudo kill -9 $p 2>/dev/null; done; pkill -9 -f vllm 2>/dev/null; sleep 12; }

say "2.1 free the card (pkill by NAME misses EngineCore workers — kill by GPU pid)"
freegpu; echo "  VRAM: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"

say "2.2 serve (--max-num-seqs 64: the 1024 default exceeds this model's Mamba cache blocks)"
mkdir -p ~/out
setsid nohup ~/venv/bin/vllm serve ~/bf16 --served-model-name local --port 8000 \
  --max-num-seqs 64 --gdn-prefill-backend triton > ~/out/srv.log 2>&1 < /dev/null &
for i in $(seq 1 120); do curl -fsS http://127.0.0.1:8000/v1/models >/dev/null 2>&1 && break; sleep 5; done
curl -fsS http://127.0.0.1:8000/v1/models >/dev/null 2>&1 || { tail -30 ~/out/srv.log; echo "FATAL: server never came up"; exit 1; }
echo "  server up on :8000 — proceed to 30-baseline.sh"
