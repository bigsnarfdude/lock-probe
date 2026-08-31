# Execution sandbox for the Lock Probe. Disposable Linux box: the model's shell runs here,
# as an unprivileged user, with NO access to the host except one mounted output dir.
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      sudo procps coreutils findutils libcap2-bin && rm -rf /var/lib/apt/lists/*
# the probe's validity invariant: an unprivileged agent that CANNOT sudo.
RUN useradd -m -s /bin/bash agent
WORKDIR /probe
COPY lib/ /probe/lib/
COPY sandbox/run-matrix.sh /probe/run-matrix.sh
RUN chmod +x /probe/run-matrix.sh
# container runs as root: root drops to `agent` passwordless; `agent` itself cannot escalate.
ENTRYPOINT ["/probe/run-matrix.sh"]
