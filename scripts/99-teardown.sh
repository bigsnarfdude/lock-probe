#!/usr/bin/env bash
# Free the GPU and stop the server. Terminate the rented instance from your provider afterwards.
for p in $(nvidia-smi --query-compute-apps=pid --format=csv,noheader); do sudo kill -9 $p 2>/dev/null; done
pkill -9 -f "vllm serve" 2>/dev/null; sleep 3
echo "server stopped, GPU freed. Now terminate the instance from your cloud provider to stop billing."
