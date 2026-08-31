#!/usr/bin/env bash
# STEP 8 — archive results OFF the rented box (it is not durable) then tear down.
# Usage: ./80-archive.sh user@durable-host:/path/to/archive
set -uo pipefail
DEST="${1:?usage: 80-archive.sh user@host:/path}"
say(){ printf "\n== %s ==\n" "$*"; }
say "8.1 record provenance"
{ date -u +%Y-%m-%dT%H:%M:%SZ; echo "model: Qwen/Qwen3.8-27B bf16 rev 1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0";
  nvidia-smi --query-gpu=name --format=csv,noheader; ~/venv/bin/python -c "import torch,vllm,transformers;print('torch',torch.__version__,'vllm',vllm.__version__,'transformers',transformers.__version__)";
  id agent; } > ~/out/PROVENANCE.txt 2>&1
( cd ~/bf16 && sha256sum *.safetensors > ~/out/bf16-shards.sha256 2>/dev/null ) || true
say "8.2 checksum every output"
( cd ~/out && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
say "8.3 rsync results (NOT weights) to the durable host"
rsync -az --exclude '*.safetensors' ~/out/ "$DEST"/ && echo "  archived to $DEST"
echo; echo "8.4 to stop billing: ./99-teardown.sh  then terminate the instance from your provider"
