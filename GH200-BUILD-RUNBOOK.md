# GH200 Build Runbook — serving a clean model for the Lock Probe flagship

The GH200 (aarch64 Grace-Hopper, 97GB) is **local-models-only** (no Ollama cloud auth). Use it to
serve a bf16/Q8 model via llama.cpp and run the flagship (recover L4T + clean pressure arms).

## Hard-won gotchas (each cost real time)
- **Run on a CLEAN, unloaded box.** Convert + serve + a second matrix at once drove load to ~30,
  which made SSH drop mid-command (Errno 255) and hung the convert. One heavy job at a time.
- **aarch64 = no easy vLLM.** vLLM needs a source build here; use **llama.cpp** (already built) instead.
- **Convert must run OFFLINE** or transformers hangs contacting the HF hub:
  `export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1` and pin `PYTHONPATH=$(python3 -m site --user-site)`.
- **Quant: Q8 minimum as a bf16 substitute. NEVER Q4** (Q4 shifted behavior; a wasted run).
- 122B models can't be bf16 on 97GB (~244GB); they're forced to Q4 → don't use them as clean points.
  27B fits: bf16 ~52GB, Q8 ~27GB — both serve cleanly.

## Prereqs (persist across reboot)
- `~/bf16` — Qwen3.8-27B bf16 safetensors, 18 shards, rev 1d4bf0f2 (verified).
- transformers installed: `pip install --user transformers safetensors numpy sentencepiece`.
- `~/llama.cpp` built (has build/bin/llama-server).

## Path A — exact bf16 (matches the H100 anchor)
```bash
cd ~/llama.cpp
export PYTHONPATH="$(python3 -m site --user-site)" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
python3 convert_hf_to_gguf.py ~/bf16 --outtype bf16 --outfile ~/qwen27b-bf16.gguf   # ~2 min on a clean box
# verify it GROWS (6->18->27->52GB); if stuck at 0% CPU, the box is loaded or hub-blocked
```

## Path B — Unsloth Q8 (smaller/faster, near-lossless bf16 substitute)
```bash
# HF egress works on the GH200 (bf16 was staged this way). Pull the Q8_0 GGUF:
python3 -c "from huggingface_hub import hf_hub_download as d; d('unsloth/Qwen3.8-27B-GGUF','Qwen3.8-27B-Q8_0.gguf',local_dir='$HOME/models/q8')"
# (confirm exact repo/filename on HF first — unsloth naming varies by model)
# OR quantize the bf16 GGUF locally if llama-quantize is built:
#   ~/llama.cpp/build/bin/llama-quantize ~/qwen27b-bf16.gguf ~/qwen27b-q8.gguf Q8_0
```

## Serve + run the flagship
```bash
SRV=~/llama.cpp/build/bin/llama-server
setsid nohup "$SRV" -m <GGUF> --host 127.0.0.1 --port 8002 -c 24576 -ngl 999 \
  --reasoning-format auto > ~/logs/serve.log 2>&1 < /dev/null &
# wait for :8002/v1/models, then run the flagship via the sandbox:
docker run --rm --network host -v ~/lock-probe-out:/out \
  -v ~/lock-probe/sandbox/run-matrix-local.sh:/probe/run-matrix-local.sh:ro \
  -e N=15 -e EFFORT=xhigh -e CONDS="neutral PC PX PXR conceal L4C L4T L4B" \
  -e MODELS=q38-27b -e MODEL_TAG=qwen3.8-27b -e QUANT=<bf16|Q8_0> \
  -e EP=http://127.0.0.1:8002/v1/chat/completions \
  --entrypoint /probe/run-matrix-local.sh lock-probe-sandbox
# results -> ~/lock-probe-out; pull to your archive host for durability.
```

## Cleanup / release
`pkill -9 -f llama-server; pkill -9 -f smoke_eval` then release the instance to stop billing.
Reboot clears orphans if SSH is too degraded to kill them.
