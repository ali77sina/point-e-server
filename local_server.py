#!/usr/bin/env python3
"""
Local Point-E Server - Runs on GPU, Apple Silicon (MPS), or CPU
Automatically detects and uses the best available device
"""

import os
import uuid
from typing import Optional
import io
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

import torch
import numpy as np
from fastapi import FastAPI, HTTPException, UploadFile, File, Form
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from PIL import Image
from tqdm.auto import tqdm

from point_e.diffusion.configs import DIFFUSION_CONFIGS, diffusion_from_config
from point_e.diffusion.sampler import PointCloudSampler
from point_e.models.download import load_checkpoint
from point_e.models.configs import MODEL_CONFIGS, model_from_config
from point_e.util.pc_to_mesh import marching_cubes_mesh
from point_e.util.point_cloud import PointCloud

# Create output directory
OUTPUT_DIR = Path("generated_models")
OUTPUT_DIR.mkdir(exist_ok=True)

# Global models
text_model = None
text_sampler = None
image_model = None  
image_sampler = None
sdf_model = None
models_ready = False
device = None

class TextRequest(BaseModel):
    prompt: str
    user_id: Optional[str] = "local"
    format: str = "mesh"
    grid_size: int = 32
    num_samples: int = 1

class GenerationResponse(BaseModel):
    success: bool
    message: str
    file_url: Optional[str] = None
    file_path: Optional[str] = None
    user_id: Optional[str] = None
    vertices: Optional[int] = None
    faces: Optional[int] = None
    device_used: Optional[str] = None
    generation_time: Optional[float] = None

def get_device():
    """Detect and return the best available device"""
    if torch.cuda.is_available():
        device = torch.device("cuda")
        device_name = f"CUDA GPU ({torch.cuda.get_device_name(0)})"
    elif hasattr(torch.backends, 'mps') and torch.backends.mps.is_available():
        device = torch.device("mps")
        device_name = "Apple Silicon GPU (MPS)"
    else:
        device = torch.device("cpu")
        device_name = "CPU"
    
    print(f"🖥️  Using device: {device_name}")
    return device, device_name

def load_models():
    """Load models with automatic device detection"""
    global text_model, text_sampler, image_model, image_sampler, sdf_model, models_ready, device
    
    device, device_name = get_device()
    print(f"⚡ Loading models on {device_name}...")
    
    if device.type == "cpu":
        print("⚠️  Note: CPU inference will be slower than GPU. Expect 2-10 minutes per generation.")
    
    try:
        # Text model
        print("📝 Loading text model...")
        text_model = model_from_config(MODEL_CONFIGS['base40M-textvec'], device)
        text_model.eval()
        text_diffusion = diffusion_from_config(DIFFUSION_CONFIGS['base40M-textvec'])
        
        # Upsampler
        print("⬆️ Loading upsampler...")
        upsampler_model = model_from_config(MODEL_CONFIGS['upsample'], device)
        upsampler_model.eval()
        upsampler_diffusion = diffusion_from_config(DIFFUSION_CONFIGS['upsample'])
        
        # Load checkpoints
        text_model.load_state_dict(load_checkpoint('base40M-textvec', device))
        upsampler_model.load_state_dict(load_checkpoint('upsample', device))
        
        # Text sampler
        text_sampler = PointCloudSampler(
            device=device,
            models=[text_model, upsampler_model],
            diffusions=[text_diffusion, upsampler_diffusion],
            num_points=[1024, 4096 - 1024],
            aux_channels=['R', 'G', 'B'],
            guidance_scale=[3.0, 0.0],
            model_kwargs_key_filter=('texts', ''),
        )
        
        # Image model (optional - skip for faster startup)
        try:
            print("🖼️ Loading image model (optional)...")
            image_model = model_from_config(MODEL_CONFIGS['base1B'], device)
            image_model.eval()
            image_diffusion = diffusion_from_config(DIFFUSION_CONFIGS['base1B'])
            image_model.load_state_dict(load_checkpoint('base1B', device))
            
            image_sampler = PointCloudSampler(
                device=device,
                models=[image_model, upsampler_model],
                diffusions=[image_diffusion, upsampler_diffusion],
                num_points=[1024, 4096 - 1024],
                aux_channels=['R', 'G', 'B'],
                guidance_scale=[3.0, 3.0],
            )
            print("✅ Image model loaded")
        except Exception as e:
            print(f"⚠️ Image model loading failed (text-to-3D will still work): {e}")
            image_model = None
            image_sampler = None
        
        # SDF model
        print("🔺 Loading SDF model...")
        sdf_model = model_from_config(MODEL_CONFIGS['sdf'], device)
        sdf_model.eval()
        sdf_model.load_state_dict(load_checkpoint('sdf', device))
        
        models_ready = True
        print(f"🚀 All models loaded successfully on {device_name}!")
        
    except Exception as e:
        print(f"❌ Model loading failed: {e}")
        models_ready = False
        raise

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    load_models()
    yield
    # Shutdown
    print("👋 Shutting down...")

app = FastAPI(
    title="Point-E Local Server", 
    version="1.0.0", 
    description="Generate 3D models locally on GPU, Apple Silicon, or CPU",
    lifespan=lifespan
)

def generate_from_text(prompt: str):
    """Generate point cloud from text"""
    if not models_ready or text_sampler is None:
        raise HTTPException(status_code=503, detail="Models not ready")
    
    import time
    start_time = time.time()
    
    samples = None
    for x in tqdm(text_sampler.sample_batch_progressive(batch_size=1, model_kwargs=dict(texts=[prompt]))):
        samples = x
    
    generation_time = time.time() - start_time
    return text_sampler.output_to_point_clouds(samples)[0], generation_time

def generate_from_image(image: Image.Image):
    """Generate point cloud from image"""
    if not models_ready or image_sampler is None:
        raise HTTPException(status_code=503, detail="Image model not available")
    
    import time
    start_time = time.time()
    
    samples = None
    for x in tqdm(image_sampler.sample_batch_progressive(batch_size=1, model_kwargs=dict(images=[image]))):
        samples = x
    
    generation_time = time.time() - start_time
    return image_sampler.output_to_point_clouds(samples)[0], generation_time

def pointcloud_to_mesh(pc: PointCloud, grid_size: int = 32):
    """Convert point cloud to mesh"""
    if not models_ready or sdf_model is None:
        raise HTTPException(status_code=503, detail="SDF model not ready")
    
    return marching_cubes_mesh(
        pc=pc,
        model=sdf_model,
        batch_size=4096,
        grid_size=grid_size,
        progress=True,
    )

def save_mesh_locally(mesh, user_id: str, prompt: str):
    """Save mesh to local directory"""
    # Create user directory
    user_dir = OUTPUT_DIR / user_id
    user_dir.mkdir(exist_ok=True)
    
    # Generate filename
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    safe_prompt = "".join(c for c in prompt if c.isalnum() or c in (' ', '-', '_')).rstrip()[:30]
    filename = f"mesh_{safe_prompt}_{timestamp}.ply"
    filepath = user_dir / filename
    
    # Save mesh
    with open(filepath, 'wb') as f:
        mesh.write_ply(f)
    
    return filepath, filename

@app.get("/")
async def root():
    _, device_name = get_device()
    return {
        "status": "Point-E Local Server", 
        "version": "1.0.0",
        "device": device_name,
        "models_ready": models_ready,
        "output_directory": str(OUTPUT_DIR.absolute()),
        "features": ["text-to-3d", "image-to-3d" if image_model else "text-to-3d only"]
    }

@app.get("/health")
async def health():
    _, device_name = get_device()
    return {
        "status": "healthy" if models_ready else "loading",
        "device": device_name,
        "models_ready": models_ready
    }

@app.post("/generate/text", response_model=GenerationResponse)
async def text_to_3d(request: TextRequest):
    """Generate 3D model from text description"""
    try:
        _, device_name = get_device()
        print(f"🎯 Generating: '{request.prompt}' on {device_name}")
        
        # Generate point cloud
        pc, generation_time = generate_from_text(request.prompt)
        
        if request.format == "mesh":
            # Convert to mesh
            mesh = pointcloud_to_mesh(pc, request.grid_size)
            
            # Save locally
            filepath, filename = save_mesh_locally(mesh, request.user_id, request.prompt)
            
            return GenerationResponse(
                success=True,
                message=f"Generated mesh: {request.prompt}",
                file_url=f"/download/{request.user_id}/{filename}",
                file_path=str(filepath),
                user_id=request.user_id,
                vertices=len(mesh.verts),
                faces=len(mesh.faces),
                device_used=device_name,
                generation_time=round(generation_time, 2)
            )
        else:
            # Point cloud format not implemented for simplicity
            raise HTTPException(status_code=400, detail="Only mesh format is supported")
            
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/generate/image", response_model=GenerationResponse)
async def image_to_3d(
    file: UploadFile = File(...), 
    user_id: str = Form("local"),
    grid_size: int = Form(32)
):
    """Generate 3D model from image"""
    try:
        if not image_model:
            raise HTTPException(status_code=503, detail="Image model not available. Use text-to-3D instead.")
        
        _, device_name = get_device()
        
        # Read image
        image_data = await file.read()
        image = Image.open(io.BytesIO(image_data))
        
        print(f"🖼️ Generating from image on {device_name}")
        
        # Generate
        pc, generation_time = generate_from_image(image)
        
        # Convert to mesh
        mesh = pointcloud_to_mesh(pc, grid_size)
        
        # Save locally
        prompt = f"from_{Path(file.filename).stem}" if file.filename else "from_image"
        filepath, filename = save_mesh_locally(mesh, user_id, prompt)
        
        return GenerationResponse(
            success=True,
            message=f"Generated mesh from image",
            file_url=f"/download/{user_id}/{filename}",
            file_path=str(filepath),
            user_id=user_id,
            vertices=len(mesh.verts),
            faces=len(mesh.faces),
            device_used=device_name,
            generation_time=round(generation_time, 2)
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/download/{user_id}/{filename}")
async def download(user_id: str, filename: str):
    """Download generated model"""
    filepath = OUTPUT_DIR / user_id / filename
    if not filepath.exists():
        raise HTTPException(status_code=404, detail="File not found")
    
    return FileResponse(filepath, filename=filename)

# Mount output directory for browsing
app.mount("/browse", StaticFiles(directory=str(OUTPUT_DIR), html=True), name="browse")

if __name__ == "__main__":
    import uvicorn
    print("🚀 Starting Point-E Local Server...")
    print(f"📁 Models will be saved to: {OUTPUT_DIR.absolute()}")
    uvicorn.run(app, host="0.0.0.0", port=8000)
