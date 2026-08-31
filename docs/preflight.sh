#!/usr/bin/env bash
# Fail loud BEFORE anything is spent. Every check here has cost us a run at least once.
set -uo pipefail
ok=0
chk(){ if eval "$2" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  FAIL  $1"; ok=1; fi; }

echo "preflight:"
chk "nvidia-smi responds"            "nvidia-smi"
chk "GPU reports >=70 GB"            "[ \$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1) -ge 70000 ]"
# A server already running is FINE if it is healthy -- that is the resume path, and the
# whole point of idempotent phases. Only a server that is up but NOT answering is stale.
if pgrep -f 'llama-server|vllm serve' >/dev/null 2>&1; then
  if curl -fsS "http://127.0.0.1:${PORT:-8000}/v1/models" >/dev/null 2>&1; then
    echo "  ok    server already up and healthy (will reuse)"
  else
    echo "  FAIL  a server process is running but not answering on :${PORT:-8000} — kill it"; ok=1
  fi
else
  echo "  ok    no stale server"
fi
chk ">=120 GB disk free"             "[ \$(df --output=avail -BG / | tail -1 | tr -dc 0-9) -ge 120 ]"
chk "passwordless sudo"              "sudo -n true"
chk "python3 >= 3.10"                "python3 -c 'import sys;sys.exit(0 if sys.version_info>=(3,10) else 1)'"
chk "curl present"                   "command -v curl"

# ---------------------------------------------------------------------------
# THE 10-SECOND TEST THAT MATTERS MOST.
#
# nvidia-smi can report a perfectly healthy H100 on a box where CUDA cannot start at
# all. We lost two rented boxes to this before checking it. An SXM card (H100 80GB
# HBM3) requires NVLink fabric initialisation; if the hypervisor passes the GPU
# through but NOT the NVSwitch, then:
#     nvidia-smi                    looks fine
#     nvidia-smi -q | grep Fabric   State: In Progress   (never becomes Completed)
#     nvidia-fabricmanager          fails: NV_WARN_NOTHING_TO_DO (nothing to manage)
#     cuInit()                      returns 802 CUDA_ERROR_SYSTEM_NOT_READY
#     llama.cpp / torch             fall back to CPU, warning only, ~50x slower
# Nothing on the tenant side fixes it. Kill the box and ask for another.
echo "  --- CUDA can actually start (802 / fabric check)"
CUINIT=$(python3 - <<'PY' 2>/dev/null
import ctypes
try: print(ctypes.CDLL("libcuda.so.1").cuInit(0))
except Exception: print("nolib")
PY
)
case "$CUINIT" in
  0)   echo "  ok    cuInit() == 0" ;;
  802) echo "  FAIL  cuInit() == 802 CUDA_ERROR_SYSTEM_NOT_READY"
       echo "        SXM GPU needs NVLink fabric; the NVSwitch was not passed through."
       echo "        Check: nvidia-smi -q | grep -A3 '^    Fabric'   -> 'In Progress' = broken."
       echo "        UNFIXABLE FROM INSIDE. Kill the box, ask the provider for another."
       ok=1 ;;
  nolib) echo "  FAIL  libcuda.so.1 not loadable"; ok=1 ;;
  *)   echo "  FAIL  cuInit() == $CUINIT"; ok=1 ;;
esac

# Boot race: a build or server started in the first couple of minutes can get
# 'system not yet initialized' and silently fall back to CPU even on a good box.
UP=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 999)
[ "$UP" -lt 180 ] && echo "  WARN  box is ${UP}s old — wait 3 min before building/serving"

exit $ok
