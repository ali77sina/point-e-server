#!/usr/bin/env python3
"""
Production Point-E Server with Google Cloud Storage
Organizes generated models by user
"""

import os
import uuid
from typing import Optional, List, Dict
import io
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
import hashlib
import hmac
import time
from collections import defaultdict

import torch
import numpy as np
from fastapi import FastAPI, HTTPException, UploadFile, File, Form, Header, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel
from PIL import Image
from tqdm.auto import tqdm

from google.cloud import storage
from google.auth.exceptions import DefaultCredentialsError

from point_e.diffusion.configs import DIFFUSION_CONFIGS, diffusion_from_config
from point_e.diffusion.sampler import PointCloudSampler
from point_e.models.download import load_checkpoint
from point_e.models.configs import MODEL_CONFIGS, model_from_config
from point_e.util.pc_to_mesh import marching_cubes_mesh
from point_e.util.point_cloud import PointCloud

# Configuration from environment
BUCKET_NAME = os.getenv('GCS_BUCKET', 'point-e-3d-models')
PROJECT_ID = os.getenv('GOOGLE_CLOUD_PROJECT', os.getenv('GCP_PROJECT_ID'))
ENABLE_GCS = os.getenv('ENABLE_GCS', 'true').lower() == 'true'

# Security configuration
SECRET_KEY = os.getenv('POINT_E_SECRET_KEY', '')
RATE_LIMIT_PER_IP = int(os.getenv('RATE_LIMIT_PER_IP', '5'))
RATE_LIMIT_WINDOW = int(os.getenv('RATE_LIMIT_WINDOW', '86400'))  # 24 hours

# Global models
text_model = None
text_sampler = None
image_model = None  
image_sampler = None
sdf_model = None
models_ready = False
gcs_client = None

# Rate limiting removed - no limits on usage

def verify_secret_key(authorization: Optional[str]) -> bool:
    """Verify the shared secret key"""
    if not SECRET_KEY:
        raise ValueError("POINT_E_SECRET_KEY must be configured for production use")
    
    if not authorization:
        return False
    
    try:
        scheme, token = authorization.split(" ", 1)
        if scheme.lower() != "bearer":
            return False
        return hmac.compare_digest(token, SECRET_KEY)
    except:
        return False

def get_forwarded_ip(request: Request) -> str:
    """Extract the original client IP from forwarded headers"""
    # Trust these headers only after secret key verification
    forwarded_for = request.headers.get("X-Forwarded-For")
    if forwarded_for:
        return forwarded_for.split(",")[0].strip()
    
    real_ip = request.headers.get("X-Real-IP")
    if real_ip:
        return real_ip
    
    original_ip = request.headers.get("X-Original-IP")
    if original_ip:
        return original_ip
    
    # Fallback to direct IP
    return request.client.host

class TextRequest(BaseModel):
    prompt: str
    user_id: Optional[str] = None
    format: str = "mesh"
    grid_size: int = 32
    num_samples: int = 1
    
class GenerationResponse(BaseModel):
    success: bool
    message: str
    file_url: Optional[str] = None
    download_url: Optional[str] = None
    user_id: Optional[str] = None
    vertices: Optional[int] = None
    faces: Optional[int] = None
    expires_at: Optional[str] = None

class UserModelsResponse(BaseModel):
    user_id: str
    models: List[dict]
    total_count: int

def setup_gcs():
    """Initialize Google Cloud Storage"""
    global gcs_client
    
    if not ENABLE_GCS:
        print("💾 GCS disabled, using local storage")
        return
    
    try:
        gcs_client = storage.Client(project=PROJECT_ID)
        
        # Create bucket if it doesn't exist
        try:
            bucket = gcs_client.bucket(BUCKET_NAME)
            if not bucket.exists():
                bucket = gcs_client.create_bucket(BUCKET_NAME, location="us-central1")
                print(f"✅ Created GCS bucket: {BUCKET_NAME}")
            else:
                print(f"✅ Using existing GCS bucket: {BUCKET_NAME}")
                
            # Set CORS for web access
            bucket.cors = [
                {
                    "origin": ["*"],
                    "method": ["GET", "HEAD"],
                    "responseHeader": ["Content-Type"],
                    "maxAgeSeconds": 3600
                }
            ]
            bucket.patch()
            
        except Exception as e:
            print(f"⚠️ GCS bucket setup issue: {e}")
            
    except DefaultCredentialsError:
        print("⚠️ GCS credentials not available - using local storage")
        gcs_client = None
    except Exception as e:
        print(f"⚠️ GCS setup failed: {e}")
        gcs_client = None

def generate_user_id(request_headers=None):
    """Generate or extract user ID"""
    # You can customize this based on your Godot authentication
    user_agent = request_headers.get('user-agent', '') if request_headers else ''
    ip = request_headers.get('x-forwarded-for', '') if request_headers else ''
    # Create a stable hash based on user agent and date
    unique_string = f"{user_agent}{ip}{datetime.now().date()}"
    return f"user_{hashlib.md5(unique_string.encode()).hexdigest()[:8]}"

def get_storage_path(user_id: str, filename: str):
    """Generate organized storage path"""
    date_folder = datetime.now().strftime('%Y/%m/%d')
    return f"users/{user_id}/{date_folder}/{filename}"

def save_to_gcs(file_content: bytes, storage_path: str, content_type: str = 'application/octet-stream'):
    """Save file to Google Cloud Storage"""
    if gcs_client is None:
        return None
    
    try:
        bucket = gcs_client.bucket(BUCKET_NAME)
        blob = bucket.blob(storage_path)
        
        blob.upload_from_string(file_content, content_type=content_type)
        
        # Generate signed URL for 30 days
        url = blob.generate_signed_url(
            version="v4",
            expiration=timedelta(days=30),
            method="GET"
        )
        
        return url
        
    except Exception as e:
        print(f"⚠️ GCS upload failed: {e}")
        return None

def save_to_local(file_content: bytes, filename: str):
    """Save to local storage"""
    os.makedirs("/tmp/point-e-models", exist_ok=True)
    local_path = f"/tmp/point-e-models/{filename}"
    
    with open(local_path, 'wb') as f:
        f.write(file_content)
    
    return f"/download/{filename}"

def load_models_fast():
    """FAST model loading - models already cached!"""
    global text_model, text_sampler, image_model, image_sampler, sdf_model, models_ready
    
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"⚡ FAST loading pre-cached models on device: {device}")
    
    try:
        # Text model - instant load from cache
        print("📝 Loading cached text model...")
        text_model = model_from_config(MODEL_CONFIGS['base40M-textvec'], device)
        text_model.eval()
        text_diffusion = diffusion_from_config(DIFFUSION_CONFIGS['base40M-textvec'])
        
        # Upsampler - instant load from cache  
        print("⬆️ Loading cached upsampler...")
        upsampler_model = model_from_config(MODEL_CONFIGS['upsample'], device)
        upsampler_model.eval()
        upsampler_diffusion = diffusion_from_config(DIFFUSION_CONFIGS['upsample'])
        
        # Load from cache (should be instant)
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
        
        # 1B image model - instant load from cache
        print("🖼️ Loading cached 1B image model...")
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
        
        # SDF model - instant load from cache
        print("🔺 Loading cached SDF model...")
        sdf_model = model_from_config(MODEL_CONFIGS['sdf'], device)
        sdf_model.eval()
        sdf_model.load_state_dict(load_checkpoint('sdf', device))
        
        models_ready = True
        print("🚀 ALL MODELS READY IN SECONDS!")
        
        # Setup storage
        setup_gcs()
        
    except Exception as e:
        print(f"❌ Model loading failed: {e}")
        models_ready = False
        raise

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup - models load in seconds from cache
    load_models_fast()
    yield
    # Shutdown

app = FastAPI(
    title="Point-E Production Server", 
    version="3.0.0", 
    description="Production-ready Point-E server with user storage",
    lifespan=lifespan
)

def generate_from_text(prompt: str):
    """Generate point cloud from text"""
    if not models_ready or text_sampler is None:
        raise HTTPException(status_code=503, detail="Models not ready")
    
    samples = None
    for x in tqdm(text_sampler.sample_batch_progressive(batch_size=1, model_kwargs=dict(texts=[prompt]))):
        samples = x
    
    return text_sampler.output_to_point_clouds(samples)[0]

def generate_from_image(image: Image.Image):
    """Generate point cloud from image"""
    if not models_ready or image_sampler is None:
        raise HTTPException(status_code=503, detail="Image model not ready")
    
    samples = None
    for x in tqdm(image_sampler.sample_batch_progressive(batch_size=1, model_kwargs=dict(images=[image]))):
        samples = x
    
    return image_sampler.output_to_point_clouds(samples)[0]

def pointcloud_to_mesh(pc: PointCloud, grid_size: int = 32):
    """Convert point cloud to mesh - optimized grid size"""
    if not models_ready or sdf_model is None:
        raise HTTPException(status_code=503, detail="SDF model not ready")
    
    return marching_cubes_mesh(
        pc=pc,
        model=sdf_model,
        batch_size=4096,
        grid_size=grid_size,
        progress=True,
    )

def save_pointcloud_ply(pc: PointCloud, filepath: str):
    """Save point cloud as PLY"""
    coords = pc.coords
    colors = pc.channels
    
    with open(filepath, 'w') as f:
        f.write("ply\nformat ascii 1.0\n")
        f.write(f"element vertex {len(coords)}\n")
        f.write("property float x\nproperty float y\nproperty float z\n")
        if 'R' in colors:
            f.write("property uchar red\nproperty uchar green\nproperty uchar blue\n")
        f.write("end_header\n")
        
        for i in range(len(coords)):
            x, y, z = coords[i]
            if 'R' in colors:
                r, g, b = int(colors['R'][i] * 255), int(colors['G'][i] * 255), int(colors['B'][i] * 255)
                f.write(f"{x} {y} {z} {r} {g} {b}\n")
            else:
                f.write(f"{x} {y} {z}\n")

@app.get("/")
async def root():
    return {
        "status": "Point-E Production Server", 
        "version": "3.0.0",
        "gpu_available": torch.cuda.is_available(),
        "models_ready": models_ready,
        "storage": "Google Cloud Storage" if gcs_client else "Local storage",
        "features": ["text-to-3d", "image-to-3d", "user-storage"],
        "authentication": "Bearer token required" if SECRET_KEY else "Not configured"
    }

@app.get("/health")
async def health():
    return {
        "status": "healthy" if models_ready else "loading", 
        "models_ready": models_ready,
        "storage_ready": gcs_client is not None,
        "production": True
    }

@app.get("/ready")
async def ready():
    """Kubernetes readiness probe"""
    if not models_ready:
        raise HTTPException(status_code=503, detail="Models not ready")
    return {"ready": True}

@app.post("/generate/text", response_model=GenerationResponse)
async def text_to_3d(
    req: Request,
    request: TextRequest, 
    user_agent: Optional[str] = Header(None), 
    x_forwarded_for: Optional[str] = Header(None),
    authorization: Optional[str] = Header(None)
):
    """⚡ FAST text-to-3D generation with user storage"""
    # Verify authentication
    if not verify_secret_key(authorization):
        raise HTTPException(status_code=401, detail="Invalid or missing authentication token")
    
    # Get forwarded IP for logging only
    original_ip = get_forwarded_ip(req)
    
    try:
        # Generate or use provided user ID
        headers = {'user-agent': user_agent, 'x-forwarded-for': x_forwarded_for}
        user_id = request.user_id or generate_user_id(headers)
        
        print(f"🎯 User {user_id} generating: '{request.prompt}' (grid_size={request.grid_size}, IP: {original_ip})")
        
        # Generate point cloud
        pc = generate_from_text(request.prompt)
        request_id = str(uuid.uuid4())[:8]
        
        # Create filename with timestamp
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        safe_prompt = "".join(c for c in request.prompt if c.isalnum() or c in (' ', '-', '_')).rstrip()[:30]
        
        if request.format == "mesh":
            # Convert to mesh
            mesh = pointcloud_to_mesh(pc, request.grid_size)
            
            # Create mesh file content
            mesh_buffer = io.BytesIO()
            mesh.write_ply(mesh_buffer)
            mesh_content = mesh_buffer.getvalue()
            
            # Save file
            filename = f"mesh_{safe_prompt}_{timestamp}_{request_id}.ply"
            
            # Try GCS first, fallback to local
            download_url = None
            if gcs_client:
                storage_path = get_storage_path(user_id, filename)
                download_url = save_to_gcs(mesh_content, storage_path, 'model/ply')
            
            if not download_url:
                # Local fallback
                file_url = save_to_local(mesh_content, filename)
                download_url = file_url
            else:
                file_url = f"/gcs/{filename}"
            
            return GenerationResponse(
                success=True,
                message=f"Generated mesh: {request.prompt}",
                file_url=file_url,
                download_url=download_url,
                user_id=user_id,
                vertices=len(mesh.verts),
                faces=len(mesh.faces),
                expires_at=(datetime.now() + timedelta(days=30)).isoformat()
            )
        else:
            # Save point cloud
            coords = pc.coords
            colors = pc.channels
            
            # Create PLY content
            ply_content = io.StringIO()
            ply_content.write("ply\nformat ascii 1.0\n")
            ply_content.write(f"element vertex {len(coords)}\n")
            ply_content.write("property float x\nproperty float y\nproperty float z\n")
            if 'R' in colors:
                ply_content.write("property uchar red\nproperty uchar green\nproperty uchar blue\n")
            ply_content.write("end_header\n")
            
            for i in range(len(coords)):
                x, y, z = coords[i]
                if 'R' in colors:
                    r, g, b = int(colors['R'][i] * 255), int(colors['G'][i] * 255), int(colors['B'][i] * 255)
                    ply_content.write(f"{x} {y} {z} {r} {g} {b}\n")
                else:
                    ply_content.write(f"{x} {y} {z}\n")
            
            ply_bytes = ply_content.getvalue().encode('utf-8')
            
            # Save file
            filename = f"pointcloud_{safe_prompt}_{timestamp}_{request_id}.ply"
            
            # Try GCS first, fallback to local
            download_url = None
            if gcs_client:
                storage_path = get_storage_path(user_id, filename)
                download_url = save_to_gcs(ply_bytes, storage_path, 'model/ply')
            
            if not download_url:
                # Local fallback
                file_url = save_to_local(ply_bytes, filename)
                download_url = file_url
            else:
                file_url = f"/gcs/{filename}"
            
            return GenerationResponse(
                success=True,
                message=f"Generated point cloud: {request.prompt}",
                file_url=file_url,
                download_url=download_url,
                user_id=user_id,
                vertices=len(pc.coords),
                faces=0,
                expires_at=(datetime.now() + timedelta(days=30)).isoformat()
            )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/generate/image", response_model=GenerationResponse)  
async def image_to_3d(
    req: Request,
    file: UploadFile = File(...), 
    format: str = Form("mesh"), 
    grid_size: int = Form(32),
    user_id: Optional[str] = Form(None),
    user_agent: Optional[str] = Header(None),
    x_forwarded_for: Optional[str] = Header(None),
    authorization: Optional[str] = Header(None)
):
    """⚡ FAST image-to-3D generation with user storage"""
    # Verify authentication
    if not verify_secret_key(authorization):
        raise HTTPException(status_code=401, detail="Invalid or missing authentication token")
    
    # Get forwarded IP for logging only
    original_ip = get_forwarded_ip(req)
    try:
        if not models_ready or image_sampler is None:
            raise HTTPException(status_code=503, detail="Image model not ready")
        
        # Generate or use provided user ID
        headers = {'user-agent': user_agent, 'x-forwarded-for': x_forwarded_for}
        user_id = user_id or generate_user_id(headers)
        
        image_data = await file.read()
        image = Image.open(io.BytesIO(image_data))
        
        print(f"🖼️ User {user_id} generating from image: {file.filename} (grid_size={grid_size}, IP: {original_ip})")
        
        pc = generate_from_image(image)
        request_id = str(uuid.uuid4())[:8]
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        
        original_name = os.path.splitext(file.filename or 'image')[0][:20]
        
        if format == "mesh":
            mesh = pointcloud_to_mesh(pc, grid_size)
            
            mesh_buffer = io.BytesIO()
            mesh.write_ply(mesh_buffer)
            mesh_content = mesh_buffer.getvalue()
            
            filename = f"mesh_from_{original_name}_{timestamp}_{request_id}.ply"
            
            # Try GCS first, fallback to local
            download_url = None
            if gcs_client:
                storage_path = get_storage_path(user_id, filename)
                download_url = save_to_gcs(mesh_content, storage_path, 'model/ply')
            
            if not download_url:
                file_url = save_to_local(mesh_content, filename)
                download_url = file_url
            else:
                file_url = f"/gcs/{filename}"
            
            return GenerationResponse(
                success=True,
                message=f"Generated mesh from image",
                file_url=file_url,
                download_url=download_url,
                user_id=user_id,
                vertices=len(mesh.verts),
                faces=len(mesh.faces),
                expires_at=(datetime.now() + timedelta(days=30)).isoformat()
            )
        else:
            # Point cloud handling similar to text generation
            pass
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/user/{user_id}/models", response_model=UserModelsResponse)
async def get_user_models(user_id: str):
    """Get all 3D models for a specific user"""
    if gcs_client is None:
        raise HTTPException(status_code=503, detail="Storage not available")
    
    try:
        bucket = gcs_client.bucket(BUCKET_NAME)
        blobs = bucket.list_blobs(prefix=f"users/{user_id}/")
        
        models = []
        for blob in blobs:
            if blob.name.endswith('.ply'):
                models.append({
                    "filename": os.path.basename(blob.name),
                    "path": blob.name,
                    "download_url": blob.generate_signed_url(version="v4", expiration=timedelta(hours=1)),
                    "created": blob.time_created.isoformat() if blob.time_created else None,
                    "size": blob.size,
                    "type": "mesh" if "mesh_" in blob.name else "pointcloud"
                })
        
        return UserModelsResponse(
            user_id=user_id,
            models=sorted(models, key=lambda x: x['created'] or '', reverse=True),
            total_count=len(models)
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list user models: {str(e)}")

@app.get("/download/{filename}")
async def download(filename: str):
    """Download generated files (local storage)"""
    filepath = f"/tmp/point-e-models/{filename}"
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail="File not found")
    
    return FileResponse(filepath, filename=filename)



if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
