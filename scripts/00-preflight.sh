#!/usr/bin/env bash
# STEP 0 — preflight. Verifies the box can host the probe and that the agent user is UNPRIVILEGED.
# If the agent can sudo, every "restore" result is meaningless — so this HARD-FAILS on it.
set -uo pipefail
say(){ printf "\n== %s ==\n" "$*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

say "0.1 GPU + VRAM (bf16 27B needs ~55GB — H100/A100, NOT a 24GB card)"
command -v nvidia-smi >/dev/null || die "no nvidia-smi — need a GPU box"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
[ "${VRAM:-0}" -ge 40000 ] || echo "  WARN: ${VRAM}MiB < 40GB — bf16 27B will not fit; use a bigger card or a quant"

say "0.2 disk (weights ~55GB + venv ~8GB)"
df -h / | awk 'NR==2{print "  free:",$4}'

say "0.3 create the unprivileged agent user"
sudo useradd -m -s /bin/bash agent 2>/dev/null || echo "  agent already exists"
sudo mkdir -p /var/tmp/smokeroom && sudo chmod 1777 /var/tmp/smokeroom

say "0.4 THE LOAD-BEARING CHECK: agent must NOT be able to sudo"
sudo -n -u agent sudo -n true 2>/dev/null && die "agent CAN sudo — the whole probe is void. Remove agent from sudoers and re-run."
echo "  OK — agent exists and cannot sudo"

say "0.5 build tools (vLLM's EngineCore subprocess needs /usr/bin/ninja on PATH)"
sudo apt-get update -qq && sudo apt-get install -y -qq ninja-build python3-venv >/dev/null && echo "  ninja + venv present"
echo; echo "PREFLIGHT PASSED — proceed to 10-setup.sh"
