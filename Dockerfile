# syntax=docker/dockerfile:1.7
# SN3 Teutonic miner — runs unarbos/teutonic miner.py against netuid 3 (finney).
# Do NOT substitute with Templar/Crusades — those are the old pre-rug mechanism.

ARG CUDA_IMAGE=nvidia/cuda:12.8.0-cudnn-runtime-ubuntu22.04
ARG TEUTONIC_SHA=1d86c2dbcc9e9b6cb2a8a9aefb1e66337d6d37e4

FROM ${CUDA_IMAGE}

ARG TEUTONIC_SHA
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/opt/hf_cache \
    UV_SYSTEM_PYTHON=1 \
    UV_LINK_MODE=copy \
    PATH=/opt/venv/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin

# System deps + Python 3.11 from deadsnakes
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common ca-certificates curl gpg-agent \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.11 python3.11-venv python3.11-dev \
        git curl jq tini \
        build-essential pkg-config \
        libssl-dev libffi-dev \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.11 /usr/local/bin/python3 \
    && ln -sf /usr/bin/python3.11 /usr/local/bin/python

# uv (for reproducible installs of the teutonic repo)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv \
    && mv /root/.local/bin/uvx /usr/local/bin/uvx

# Clone teutonic at a pinned commit
RUN git clone https://github.com/unarbos/teutonic /opt/teutonic \
    && cd /opt/teutonic \
    && git checkout ${TEUTONIC_SHA} \
    && git rev-parse HEAD > /opt/teutonic/.pinned-sha

WORKDIR /opt/teutonic

# Create a venv and install deps. Try uv pip first (fast, hermetic), fall back
# to plain pip. We install into a venv at /opt/venv so PATH works for non-root.
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip wheel setuptools \
    && (uv pip install --python /opt/venv/bin/python --no-cache \
         'bittensor>=9.0.0' boto3 httpx 'numpy<2' scipy huggingface-hub \
         torch safetensors transformers \
         || /opt/venv/bin/pip install --no-cache-dir \
              'bittensor>=9.0.0' boto3 httpx 'numpy<2' scipy huggingface-hub \
              torch safetensors transformers) \
    && /opt/venv/bin/pip install --no-cache-dir -e /opt/teutonic || true

# btcli is provided by bittensor; ensure it's on PATH
RUN ln -sf /opt/venv/bin/btcli /usr/local/bin/btcli || true

# Non-root user. CUDA runtime works fine for non-root when /dev/nvidia* is
# exposed by nvidia-container-toolkit.
RUN groupadd -g 1000 miner \
    && useradd -m -u 1000 -g 1000 -s /bin/bash miner \
    && mkdir -p /opt/hf_cache /home/miner/.bittensor/wallets \
    && chown -R miner:miner /opt/hf_cache /home/miner /opt/teutonic

# Copy runtime files
COPY --chown=miner:miner entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=miner:miner miner_wrapper.py /opt/teutonic/miner_wrapper.py
RUN chmod +x /usr/local/bin/entrypoint.sh

USER miner
WORKDIR /opt/teutonic

# Healthcheck: confirm the wrapper has written a recent heartbeat in the last
# 20 minutes. The wrapper touches /tmp/teutonic-heartbeat after each submit or
# poll cycle.
HEALTHCHECK --interval=60s --timeout=10s --start-period=180s --retries=3 \
    CMD test -f /tmp/teutonic-heartbeat \
        && find /tmp/teutonic-heartbeat -mmin -20 | grep -q . || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
