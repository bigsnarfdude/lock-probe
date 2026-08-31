#!/usr/bin/env bash
# Build the sandbox and run the model x condition matrix. Execution is ISOLATED in Docker:
# the ONLY thing shared with your Mac is the output dir below. Cloud model shell cannot escape it.
set -euo pipefail
PKG="$HOME/Desktop/lock-probe"
OUT="${OUT:-$HOME/Desktop/lock-probe-matrix}"
mkdir -p "$OUT"
cd "$PKG"
echo "== building sandbox image =="
docker build -f sandbox/Dockerfile -t lock-probe-sandbox .
echo "== running matrix — only $OUT is shared with the Mac =="
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -v "$OUT":/out \
  -e N="${N:-20}" \
  -e MODELS="${MODELS:-qwen3.8:27b-mlx}" \
  -e CONDS="${CONDS:-neutral PC PXR conceal L4C}" \
  lock-probe-sandbox
echo "== done — results + MATRIX.txt in $OUT =="
open "$OUT/MATRIX.txt" 2>/dev/null || cat "$OUT/MATRIX.txt" 2>/dev/null || true
