#!/usr/bin/env bash
# STEP 1 — deps + weights + scorer self-test. Idempotent: re-running skips finished work.
set -uo pipefail
say(){ printf "\n== %s ==\n" "$*"; }; die(){ echo "FATAL: $*" >&2; exit 1; }
MODEL="Qwen/Qwen3.8-27B"
REV="1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"   # pin the exact snapshot this probe was built on
HERE="$(cd "$(dirname "$0")/.." && pwd)"

say "1.1 venv + libraries"
[ -d ~/venv ] || python3 -m venv ~/venv
~/venv/bin/pip install -q --upgrade pip
~/venv/bin/pip install -q vllm transformers accelerate safetensors "huggingface_hub[hf_transfer]" || die "pip failed"
~/venv/bin/python -c "import torch;assert torch.cuda.is_available();print('  torch',torch.__version__,torch.cuda.get_device_name(0))" || die "torch cannot see the GPU"

say "1.2 scorer self-test (NO GPU, NO model — catches scorer bugs before you spend money)"
~/venv/bin/python "$HERE/lib/selftest.py" || die "self-test failed — the scorers are wrong, do not continue"

say "1.3 download weights at the pinned revision (~55GB)"
if [ -f ~/bf16/config.json ] && [ "$(du -sm ~/bf16 2>/dev/null|cut -f1)" -ge 45000 ]; then
  echo "  weights already present — skipping"
else
  HF_HUB_ENABLE_HF_TRANSFER=1 ~/venv/bin/python -c "
from huggingface_hub import snapshot_download
snapshot_download('$MODEL', revision='$REV', local_dir='$HOME/bf16'); print('WEIGHTS DONE')" || die "download failed"
fi

say "1.4 verify shard integrity against HF-recorded hashes (provenance)"
[ -f "$HERE/docs/bf16-shards.sha256" ] && ( cd ~/bf16 && sha256sum -c "$HERE/docs/bf16-shards.sha256" 2>&1 | tail -3 ) || echo "  (no reference hashes shipped — skip; add docs/bf16-shards.sha256 to enable)"
echo; echo "SETUP DONE — proceed to 20-serve.sh"
