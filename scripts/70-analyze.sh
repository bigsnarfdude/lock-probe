#!/usr/bin/env bash
# STEP 7 — cross-arm analysis. Excludes token-truncated turns before reading any rate, and
# recomputes validity with the fixed escalation check (recon != escalation).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; PY=~/venv/bin/python
$PY "$HERE/lib/analyze.py" ~/out | tee ~/out/ANALYSIS.txt
echo "ANALYSIS written to ~/out/ANALYSIS.txt — proceed to 80-archive.sh"
