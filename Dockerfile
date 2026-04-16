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
    PATH=/opt/venv/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# System deps + Python 3.11 from deadsnakes
# passwd provides useradd/groupadd (not present in minimal CUDA runtime image)
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common ca-certificates curl gpg-agent \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.11 python3.11-venv python3.11-dev \
        git curl jq tini \
        build-essential pkg-config \
        libssl-dev libffi-dev \
        passwd adduser login \
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
    && git rev-parse HEAD > /opt/teutonic/.pinned-sha \
    # Patch miner.py so the challenger repo uses $HF_USER (if set) instead of
    # the hardcoded "unconst" org. Upstream has `challenger_repo = f"unconst/Teutonic-I-{suffix}"`
    # and the dashboard shows competitors pushing under their own HF namespaces.
    && sed -i 's|challenger_repo = f"unconst/Teutonic-I-{suffix}"|challenger_repo = f"{os.environ.get(\"HF_USER\") or \"unconst\"}/Teutonic-I-{suffix}"|' /opt/teutonic/miner.py \
    && grep -n "challenger_repo = " /opt/teutonic/miner.py

WORKDIR /opt/teutonic

# Create a venv and install deps. Use plain pip with pinned numpy (1.26.4 has
# cp311 manylinux wheels; unpinned 'numpy<2' sometimes resolves to a sdist and
# tries to compile via Cython, which breaks on minimal CUDA images).
# Torch CUDA 12.1 wheels work fine on CUDA 12.8 driver runtimes.
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade 'pip>=24.0' wheel setuptools \
    && /opt/venv/bin/pip install --no-cache-dir 'numpy==1.26.4' \
    && /opt/venv/bin/pip install --no-cache-dir \
         --index-url https://download.pytorch.org/whl/cu121 \
         'torch==2.4.1+cu121' \
    && /opt/venv/bin/pip install --no-cache-dir \
         'bittensor>=9.0.0' boto3 httpx scipy 'huggingface-hub>=0.24' \
         safetensors 'transformers>=4.44' \
    && /opt/venv/bin/pip install --no-cache-dir -e /opt/teutonic || true

# btcli is provided by bittensor; ensure it's on PATH
RUN ln -sf /opt/venv/bin/btcli /usr/local/bin/btcli || true

# Non-root user. CUDA runtime works fine for non-root when /dev/nvidia* is
# exposed by nvidia-container-toolkit. Use absolute paths since /usr/sbin may
# not be on PATH during RUN in some base images.
RUN which groupadd || ls -la /usr/sbin/groupadd /sbin/groupadd 2>&1 || true \
    && /usr/sbin/groupadd -g 1000 miner \
    && /usr/sbin/useradd -m -u 1000 -g 1000 -s /bin/bash miner \
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
