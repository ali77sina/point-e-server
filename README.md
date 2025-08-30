# Point-E Server

Production-ready GPU-accelerated server for OpenAI's Point-E text-to-3D generation model.

## Features

- 🚀 GPU-accelerated inference (30 seconds per generation)
- 📦 Pre-cached models in Docker image for instant startup
- 🔧 RESTful API with automatic documentation
- ☁️ Ready for Google Cloud deployment (GKE, Compute Engine)
- ⚡ Auto-scaling support with load balancing
- 🏠 Local server with automatic device detection (GPU/MPS/CPU)
- 💾 Google Cloud Storage integration for production deployments

## Quick Start

### Local Development

Run Point-E locally on your machine with automatic device detection:

```bash
# Install dependencies
pip install -r requirements.txt
pip install git+https://github.com/openai/CLIP.git

# Run local server (auto-detects GPU/MPS/CPU)
python local_server.py
```

The local server will:
- ✅ Automatically detect and use NVIDIA GPU if available
- ✅ Use Apple Silicon GPU (MPS) on M1/M2 Macs
- ✅ Fall back to CPU if no GPU is available
- 📁 Save generated models to `generated_models/` directory

**Performance:**
- GPU (NVIDIA/Apple): ~30-60 seconds per model
- CPU: 2-10 minutes per model (varies by hardware)

### Docker (Production)

```bash
# Build image with pre-cached models
docker build -t point-e-server .

# Run with GPU
docker run --gpus all -p 8000:8000 point-e-server
```

## API Usage

### Generate 3D Model

```bash
curl -X POST http://localhost:8000/generate/text \
  -H "Content-Type: application/json" \
  -d '{"prompt": "a red chair", "user_id": "test-user"}'
```

### Check Device Info (Local Server)

```bash
curl http://localhost:8000/
```

Returns device being used (GPU/MPS/CPU) and output directory.

### Health Check

```bash
curl http://localhost:8000/health
```

### Browse Generated Models (Local Server)

Visit `http://localhost:8000/browse` to see all generated models.

### API Documentation

- 📖 **[Full API Reference](API.md)** - Complete documentation with examples
- 🔧 **Interactive Docs** - Visit `http://localhost:8000/docs` when server is running

## Deployment

### Google Cloud Platform Setup

1. **Configure your project**:
   ```bash
   cp config.sh.example config.sh
   # Edit config.sh with your GCP project ID and settings
   source config.sh
   ```

2. **Build and push the Docker image**:
   ```bash
   ./scripts/build-image.sh
   ```

3. **Deploy to GCP** (see deployment guide for full instructions):
   - Create GPU-enabled instance group
   - Set up load balancer
   - Configure auto-scaling

4. **Update deployment** (after code changes):
   ```bash
   ./scripts/update-point-e.sh
   ```

### Features

- **Google Cloud Storage**: Generated models are saved to GCS, organized by user
- **Auto-scaling**: Scales 1-5 instances based on load
- **GPU acceleration**: Uses NVIDIA L4 GPUs for ~30 second generation
- **Pre-cached models**: Fast startup times (~2 minutes)

## Which Server to Use?

- **`local_server.py`** - For local development and testing
  - Auto-detects GPU/MPS/CPU
  - Saves files locally
  - No cloud dependencies
  - Perfect for experimentation

- **`server.py`** - For production deployments
  - Optimized for Google Cloud
  - Supports Google Cloud Storage
  - Ready for auto-scaling
  - Load balancer compatible

## Project Structure

```
.
├── local_server.py        # Local development server
├── server.py              # Production server (GCS support)
├── requirements.txt       # Python dependencies
├── Dockerfile            # Production Docker image
├── point_e/              # Point-E model source
├── k8s/                  # Kubernetes manifests
├── scripts/              # Deployment scripts
├── tests/                # API tests
└── generated_models/     # Local output directory
```

## Security Note

This project includes authentication and rate limiting features:
- **Shared Secret Authentication**: Set `POINT_E_SECRET_KEY` environment variable
- **Rate Limiting**: 5 generations per IP per day (configurable)
- **Safe for Open Source**: All sensitive configuration uses environment variables

Never commit your actual `config.sh` or secret keys to the repository!

## Configuration

### Setting up for your project

1. Copy `config.sh.example` to `config.sh`:
   ```bash
   cp config.sh.example config.sh
   ```

2. Edit `config.sh` with your Google Cloud project details:
   ```bash
   export GCP_PROJECT_ID="your-project-id"
   export DEPLOYMENT_AUTHOR="your-name"
   ```

3. Source the configuration before running scripts:
   ```bash
   source config.sh
   ./scripts/build-image.sh
   ```

## License

MIT License - See LICENSE file for details