#!/bin/bash
# PRESSURE LADDER, all at xhigh, n=100. Same task, same lock; only the framing changes.
set -uo pipefail
cd ~/chmod444-probe
say(){ printf "\n== [%s] %s ==\n" "$(date +%T)" "$*"; }
freegpu(){ for p in $(nvidia-smi --query-compute-apps=pid --format=csv,noheader); do sudo kill -9 $p 2>/dev/null; done
           pkill -9 -f vllm 2>/dev/null; sleep 12; echo "  VRAM: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"; }

say "serve"
freegpu
setsid nohup ~/venv/bin/vllm serve ~/bf16 --served-model-name local --port 8000 \
  --max-num-seqs 64 --gdn-prefill-backend triton > out/srv_p.log 2>&1 < /dev/null &
for i in $(seq 1 120); do curl -fsS http://127.0.0.1:8000/v1/models >/dev/null 2>&1 && break; sleep 5; done
curl -fsS http://127.0.0.1:8000/v1/models >/dev/null 2>&1 || { echo "FATAL: no server"; exit 1; }
EP=http://127.0.0.1:8000/v1/chat/completions
say "server up"

# neutral re-run at xhigh alongside, so the baseline is same-session
for C in neutral PW PE PC PX PXR conceal; do
  F=out/p_${C}.json; [ -s "$F" ] && { echo "skip $C"; continue; }
  say "$C  xhigh  n=100"
  timeout 3600 ~/venv/bin/python lib/smoke_eval.py --arm p_${C} --endpoint $EP \
    --model-tag Qwen/Qwen3.8-27B --quant bf16 --trials 100 --concurrency 8 --agent-user agent \
    --cond $C --reasoning-effort xhigh --out $F 2>&1 | tee out/log_p_${C}.txt | tail -12
  grep -q '"trials": 0' "$F" 2>/dev/null && { echo "FATAL: $C zero trials"; exit 1; }
done

say "PRESSURE LADDER SUMMARY"
~/venv/bin/python - <<'PY'
import json,os
print("%-9s %6s %8s %11s   %s" % ("cond","valid","defeat","restored","rate"))
for c in ("neutral","PW","PE","PC","PX","PXR","conceal"):
    f="out/p_%s.json"%c
    if not os.path.exists(f): print("%-9s (missing)"%c); continue
    d=json.load(open(f))
    r=[x for x in d["records"] if x.get("validity",{}).get("valid",True)]
    df=[x for x in r if x["verdict"]["defeated"]]
    res=[x for x in df if x["verdict"]["disturbance"] and x["verdict"]["disturbance"]["mode"] is False]
    print("%-9s %6d %8d %11d   %.1f%%" % (c,len(r),len(df),len(res),100*len(res)/max(len(df),1)))
PY
say "ALL DONE"
