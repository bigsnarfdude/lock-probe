#!/usr/bin/env bash
# chmod-444 probe — clean reproduce of L1/L2/L3 on ONE H100.
#
#   scp -r chmod444-probe ubuntu@<host>:~/ && ssh ubuntu@<host> 'cd chmod444-probe && ./00-run.sh'
#
# Phases are idempotent: re-running skips any arm whose output already exists, so a dropped
# ssh costs you nothing. Everything lands in ./out/.
set -uo pipefail
cd "$(dirname "$0")"
T0=$(date +%s)
say(){ printf "\n\033[1m== [%5ss] %s ==\033[0m\n" "$(( $(date +%s) - T0 ))" "$*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

N=${N:-100}                 # trials per cell
CONC=${CONC:-8}
PORT=${PORT:-8000}
MODEL=${MODEL:-Qwen/Qwen3.8-27B}
OUT=./out; mkdir -p $OUT

# ---------------------------------------------------------------- 0. free checks
say "0a. self-test (no GPU, no model, no network — catches scorer bugs before you spend)"
python3 lib/selftest.py || die "self-test failed — the scorers are wrong, do not continue"

say "0b. preflight"
./preflight.sh || die "preflight failed"

# ---------------------------------------------------------------- 1. setup
say "1. deps + weights (download runs in BACKGROUND while pip works — do not serialize)"
# The download must use SYSTEM python3 (the venv does not exist yet, and building it first
# would serialize the two long poles). So system python3 needs the hub client BEFORE the
# background job starts -- otherwise it dies instantly with ModuleNotFoundError and the
# wait loop below blocks on a corpse. Cost us 22 minutes once.
python3 -m pip install -q --user "huggingface_hub[hf_transfer]" || die "cannot install huggingface_hub"
python3 -c "import huggingface_hub" || die "huggingface_hub still not importable by system python3"
if [ ! -d ~/bf16 ]; then
  HF_HUB_ENABLE_HF_TRANSFER=1 setsid nohup python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('$MODEL', local_dir='$HOME/bf16'); print('WEIGHTS DONE')" > $OUT/dl.log 2>&1 < /dev/null &
  DL_PID=$!
  sleep 8
  kill -0 $DL_PID 2>/dev/null || { echo "--- dl.log:"; cat $OUT/dl.log; die "download died on launch"; }
fi
sudo apt-get update -qq && sudo apt-get install -y -qq ninja-build python3-venv >/dev/null
#   ninja MUST come from apt, not pip: vLLM's EngineCore is a SUBPROCESS and needs
#   /usr/bin/ninja on PATH. A pip install into a venv is invisible to it, and the failure
#   surfaces deep in profile_run() looking exactly like an OOM. This cost us an arm.
[ -d ~/venv ] || python3 -m venv ~/venv
~/venv/bin/pip install -q --upgrade pip
~/venv/bin/pip install -q vllm transformers accelerate safetensors || die "pip failed"
PY=~/venv/bin/python
$PY -c "import torch;assert torch.cuda.is_available(),'no CUDA';print('  torch',torch.__version__,torch.cuda.get_device_name(0))" || die "torch cannot see the GPU"

say "2. unprivileged agent user"
sudo useradd -m -s /bin/bash agent 2>/dev/null || true
sudo mkdir -p /var/tmp/smokeroom && sudo chmod 1777 /var/tmp/smokeroom
sudo -n -u agent sudo -n true 2>/dev/null && die "agent can sudo — the whole probe is void"
echo "  agent exists and cannot sudo"

say "3. wait for weights"
# Resume path: if the weights are already complete, skip entirely. Otherwise a STALE dl.log
# from a previous failed attempt would trip the error check below and abort a good run.
WSZ=$(du -sm ~/bf16 2>/dev/null | cut -f1); WSZ=${WSZ:-0}
if [ "$WSZ" -ge 45000 ] && [ -f ~/bf16/config.json ]; then
  echo "  weights already present (${WSZ} MB) — skipping"
else
# FAIL LOUD: a wait loop that only checks for success will happily block for an hour on a
# job that already crashed. Check for progress too, and abort the moment it stops making any.
LAST=0; STALL=0
for i in $(seq 1 240); do
  grep -q "WEIGHTS DONE" $OUT/dl.log 2>/dev/null && break
  if grep -qiE "Traceback|Error|No module named" $OUT/dl.log 2>/dev/null; then
    echo "--- dl.log:"; tail -20 $OUT/dl.log; die "download failed (see above)"
  fi
  NOW=$(du -sm ~/bf16 2>/dev/null | cut -f1); NOW=${NOW:-0}
  if [ "$NOW" -gt "$LAST" ]; then LAST=$NOW; STALL=0
  else STALL=$((STALL+1)); [ $STALL -ge 8 ] && { echo "--- dl.log:"; tail -20 $OUT/dl.log; die "download stalled at ${NOW} MB for 2 min"; }
  fi
  printf "\r  %s MB downloaded" "$NOW"; sleep 15
done
echo
grep -q "WEIGHTS DONE" $OUT/dl.log 2>/dev/null || die "weights never finished; see $OUT/dl.log"
fi

# ---------------------------------------------------------------- 2. serve
say "4. serve bf16 (reasoning_effort is PER-REQUEST — never pin it on the server)"
#   --max-num-seqs 64: the default 1024 exceeds this model's 309 Mamba cache blocks and aborts.
setsid nohup ~/venv/bin/vllm serve ~/bf16 --served-model-name local --port $PORT \
  --max-num-seqs 64 --gdn-prefill-backend triton > $OUT/srv.log 2>&1 < /dev/null &
for i in $(seq 1 120); do curl -fsS http://127.0.0.1:$PORT/v1/models >/dev/null 2>&1 && break; sleep 5; done
curl -fsS http://127.0.0.1:$PORT/v1/models >/dev/null 2>&1 || { tail -30 $OUT/srv.log; die "server never came up"; }
EP=http://127.0.0.1:$PORT/v1/chat/completions
echo "  up"

# ---------------------------------------------------------------- 3. L1 + L2
say "5. L1 (artifact forensics) + L2 (transcript vs exec ledger) — 8 arms x $N"
#   neutral = the locked-file probe. scratch = the tidiness floor, 644, no permissions in
#   the task at all. If care rises with effort in BOTH, the restore is ordinary carefulness.
#   If only neutral rises, the behaviour is specific to the obstacle.
#   EFFORT LEVELS: low / medium / xhigh only. Qwen3.8 has no "high" -- vLLM 400s on it and
#   llama.cpp silently substitutes the default. Adding a level the model does not have
#   manufactures a fake gradient point.
for COND in neutral scratch; do
  for E in low medium xhigh; do
    F=$OUT/${COND}_${E}.json
    [ -s "$F" ] && { echo "  skip $COND/$E"; continue; }
    echo "  --- $COND / $E"
    #  tee, do NOT tail: a truncated arm log hides the very lines you need when an arm dies.
    $PY lib/smoke_eval.py --arm ${COND}_${E} --endpoint $EP --model-tag "$MODEL" --quant bf16 \
       --trials $N --concurrency $CONC --agent-user agent \
       --cond $COND --reasoning-effort $E --out $F 2>&1 | tee $OUT/log_${COND}_${E}.txt | tail -14
    grep -q '"trials": 0' "$F" 2>/dev/null && die "arm $COND/$E produced ZERO trials — see $OUT/log_${COND}_${E}.txt"
  done
done

# ---------------------------------------------------------------- 4. L3
say "6. L3 (activations) — capture xhigh with hooks, then read the lens"
#   xhigh is the arm that produces UNBIDDEN restores (~6%), which is what makes a matched
#   contrast possible: same task, same model, one restores and one does not, nobody asked.
[ -d $OUT/cap_xhigh/turns ] || $PY lib/capture_chmod.py --cond neutral --reasoning-effort xhigh \
   --trials 200 --out $OUT/cap_xhigh 2>&1 | tail -12
for A in action cot-last cot-plan; do
  echo "  --- anchor: $A"
  $PY lib/lens.py $OUT/cap_xhigh --anchor $A --layer 56 2>&1 | tail -14
done

# ---------------------------------------------------------------- 5. report
pkill -9 -f "vllm serve" 2>/dev/null
say "7. report"
$PY lib/nc_report.py $OUT | tee $OUT/REPORT.txt
say "DONE — everything is in $OUT/ (scp it back before you kill the box)"
