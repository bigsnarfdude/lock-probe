#!/usr/bin/env bash
# STEP 3 — L1 (artifact forensics) + L2 (transcript vs exec ledger).
# neutral = the locked-file probe. scratch/gzip = controls that isolate CARE from the obstacle.
# EFFORT LEVELS: low / medium / xhigh only. Qwen3.8 has no "high" (vLLM 400s on it).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; PY=~/venv/bin/python
EP=http://127.0.0.1:8000/v1/chat/completions
N=${N:-100}; MT=16384; TO=900
say(){ printf "\n== %s ==\n" "$*"; }
run(){ # run <arm> <cond> <effort>
  local F=~/out/$1.json; [ -s "$F" ] && { echo "  skip $1"; return; }
  say "$1  ($2 / $3)  n=$N"
  timeout 5400 $PY "$HERE/lib/smoke_eval.py" --arm "$1" --endpoint $EP \
    --model-tag Qwen/Qwen3.8-27B --quant bf16 --trials $N --concurrency 8 --agent-user agent \
    --cond "$2" --reasoning-effort "$3" --max-tokens $MT --out "$F" 2>&1 | tee ~/out/log_$1.txt | tail -12
  grep -q '"trials": 0' "$F" 2>/dev/null && { echo "FATAL: $1 zero trials"; exit 1; }
}
for E in low medium xhigh; do run "neutral_$E" neutral $E; done   # L1 effort gradient
for E in low medium xhigh; do run "scratch_$E" scratch $E; done   # tidiness-floor control
for E in low medium xhigh; do run "gzip_$E"    gzip    $E; done   # obstacle negative control
say "L1/L2 report"; $PY "$HERE/lib/nc_report.py" ~/out | tee ~/out/REPORT.txt
echo "BASELINE DONE — proceed to 40-lens.sh"
