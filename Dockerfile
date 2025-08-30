# Production Point-E Server - Pre-cached Models
# Optimized for GKE autoscaling with instant startup

FROM nvidia/cuda:12.9.1-cudnn-runtime-ubuntu22.04

WORKDIR /app

# Install system deps (including NVIDIA runtime will be handled by K8s)
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    python3 python3-pip git curl wget \
    && rm -rf /var/lib/apt/lists/*

# Install Python deps with CUDA support (matching your working setup)
COPY requirements.txt .
RUN pip3 install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
RUN pip3 install --no-cache-dir -r requirements.txt
RUN pip3 install --no-cache-dir git+https://github.com/openai/CLIP.git

# Copy Point-E source
COPY point_e/ ./point_e/

# PRE-DOWNLOAD ALL MODELS AT BUILD TIME (NOT RUNTIME!)
RUN python3 -c "\
import torch; \
from point_e.models.download import load_checkpoint; \
from point_e.models.configs import MODEL_CONFIGS, model_from_config; \
from point_e.diffusion.configs import DIFFUSION_CONFIGS, diffusion_from_config; \
print('🚀 PRE-DOWNLOADING MODELS AT BUILD TIME...'); \
device = torch.device('cpu'); \
print('📝 Downloading text model...'); \
load_checkpoint('base40M-textvec', device); \
print('⬆️ Downloading upsampler...'); \
load_checkpoint('upsample', device); \
print('🖼️ Downloading 1B image model...'); \
load_checkpoint('base1B', device); \
print('🔺 Downloading SDF model...'); \
load_checkpoint('sdf', device); \
print('✅ ALL MODELS PRE-CACHED!'); \
"

# Production optimized server
COPY server.py .

# Create model cache directory with proper permissions
RUN mkdir -p /root/.cache && chmod 755 /root/.cache

EXPOSE 8000

# Optimized health check - models already loaded
HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=2 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["python3", "server.py"]
