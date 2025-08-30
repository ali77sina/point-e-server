#!/bin/bash
# Authentication setup script for Point-E server
# Adds API key authentication to protect your GPU resources

set -e

source config.sh

echo "🔐 Setting up API authentication for Point-E server..."

# Step 1: Create API keys in Google Secret Manager
echo "🗝️  Creating API keys..."

# Enable Secret Manager API
gcloud services enable secretmanager.googleapis.com --project=${GCP_PROJECT_ID}

# Generate a master API key
MASTER_API_KEY=$(openssl rand -hex 32)
echo "Generated master API key: ${MASTER_API_KEY}"

# Store in Secret Manager
gcloud secrets create point-e-master-api-key \
    --data-file=<(echo -n "${MASTER_API_KEY}") \
    --project=${GCP_PROJECT_ID} || echo "Master key secret already exists"

# Create some example user API keys
USER_API_KEY_1=$(openssl rand -hex 32)
USER_API_KEY_2=$(openssl rand -hex 32)

gcloud secrets create point-e-user-api-keys \
    --data-file=<(echo -e "${USER_API_KEY_1}:user1\n${USER_API_KEY_2}:user2") \
    --project=${GCP_PROJECT_ID} || echo "User keys secret already exists"

echo "User API Key 1: ${USER_API_KEY_1} (user1)"
echo "User API Key 2: ${USER_API_KEY_2} (user2)"

# Step 2: Create authentication middleware for the server
echo "🔧 Creating authentication middleware..."

cat > auth_middleware.py << 'EOF'
import os
import logging
from fastapi import HTTPException, Request, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from google.cloud import secretmanager
from typing import Dict, Optional
import hashlib
import time

logger = logging.getLogger(__name__)

class APIKeyAuth:
    def __init__(self, project_id: str):
        self.project_id = project_id
        self.client = secretmanager.SecretManagerServiceClient()
        self.valid_keys: Dict[str, str] = {}
        self.last_refresh = 0
        self.refresh_interval = 300  # 5 minutes
        
    def _load_api_keys(self):
        """Load API keys from Secret Manager"""
        try:
            # Load user API keys
            user_keys_name = f"projects/{self.project_id}/secrets/point-e-user-api-keys/versions/latest"
            response = self.client.access_secret_version(request={"name": user_keys_name})
            user_keys_data = response.payload.data.decode("UTF-8")
            
            self.valid_keys = {}
            for line in user_keys_data.strip().split('\n'):
                if ':' in line:
                    key, user_id = line.split(':', 1)
                    self.valid_keys[key.strip()] = user_id.strip()
            
            # Load master key
            master_key_name = f"projects/{self.project_id}/secrets/point-e-master-api-key/versions/latest"
            response = self.client.access_secret_version(request={"name": master_key_name})
            master_key = response.payload.data.decode("UTF-8")
            self.valid_keys[master_key] = "admin"
            
            self.last_refresh = time.time()
            logger.info(f"Loaded {len(self.valid_keys)} API keys")
            
        except Exception as e:
            logger.error(f"Failed to load API keys: {e}")
            if not self.valid_keys:  # If no keys loaded, use emergency fallback
                logger.warning("Using emergency fallback API key")
                self.valid_keys = {"emergency-key-change-me": "admin"}
    
    def verify_api_key(self, api_key: str) -> Optional[str]:
        """Verify API key and return user ID"""
        # Refresh keys if needed
        if time.time() - self.last_refresh > self.refresh_interval:
            self._load_api_keys()
        
        return self.valid_keys.get(api_key)
    
    def get_rate_limit_key(self, api_key: str, ip: str) -> str:
        """Generate rate limit key based on API key and IP"""
        return hashlib.sha256(f"{api_key}:{ip}".encode()).hexdigest()[:16]

# Rate limiting
class RateLimiter:
    def __init__(self):
        self.requests: Dict[str, list] = {}
        self.limits = {
            "admin": {"requests": 100, "window": 60},  # 100 req/min for admin
            "user": {"requests": 10, "window": 60},    # 10 req/min for users
        }
    
    def is_allowed(self, key: str, user_type: str = "user") -> bool:
        """Check if request is allowed under rate limit"""
        now = time.time()
        limit_config = self.limits.get(user_type, self.limits["user"])
        
        if key not in self.requests:
            self.requests[key] = []
        
        # Clean old requests
        self.requests[key] = [
            req_time for req_time in self.requests[key]
            if now - req_time < limit_config["window"]
        ]
        
        # Check limit
        if len(self.requests[key]) >= limit_config["requests"]:
            return False
        
        # Add current request
        self.requests[key].append(now)
        return True

# Initialize global instances
api_auth = APIKeyAuth(os.getenv("GCP_PROJECT_ID", ""))
rate_limiter = RateLimiter()
security = HTTPBearer()

async def verify_api_key(request: Request, credentials: HTTPAuthorizationCredentials = security):
    """FastAPI dependency for API key verification"""
    api_key = credentials.credentials
    user_id = api_auth.verify_api_key(api_key)
    
    if not user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API key"
        )
    
    # Rate limiting
    client_ip = request.client.host
    rate_key = api_auth.get_rate_limit_key(api_key, client_ip)
    user_type = "admin" if user_id == "admin" else "user"
    
    if not rate_limiter.is_allowed(rate_key, user_type):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Rate limit exceeded"
        )
    
    # Add user info to request state
    request.state.user_id = user_id
    request.state.api_key = api_key
    request.state.is_admin = user_id == "admin"
    
    return user_id

# Load API keys on startup
api_auth._load_api_keys()
EOF

# Step 3: Update the main server to use authentication
echo "🔄 Creating authenticated server version..."

cat > server_with_auth.py << 'EOF'
import os
import sys
import logging
from fastapi import FastAPI, HTTPException, UploadFile, File, Form, Depends, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional
import uvicorn

# Import authentication
from auth_middleware import verify_api_key

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Point-E 3D Generation API (Authenticated)",
    description="Generate 3D models from text or images with API key authentication",
    version="2.0.0"
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure this for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Import your existing Point-E server code here
# This is a template - you'll need to integrate with your actual server.py

@app.get("/")
async def root():
    return {
        "status": "Point-E Production Server (Authenticated)",
        "version": "2.0.0",
        "authentication": "API Key Required",
        "rate_limits": {
            "admin": "100 requests/minute",
            "user": "10 requests/minute"
        }
    }

@app.get("/health")
async def health_check():
    """Public health check endpoint"""
    return {"status": "healthy", "authentication": "enabled"}

@app.post("/generate/text")
async def generate_from_text(
    request: Request,
    text_request: dict,  # Replace with your TextRequest model
    user_id: str = Depends(verify_api_key)
):
    """Generate 3D model from text - requires API key"""
    logger.info(f"Text generation request from user {user_id}: {text_request.get('prompt', '')}")
    
    # Use the authenticated user_id instead of the one in the request
    text_request['user_id'] = user_id
    
    # Your existing text generation code here
    # return generate_text_model(text_request)
    return {"message": "Text generation endpoint - integrate your existing code here"}

@app.post("/generate/image")
async def generate_from_image(
    request: Request,
    file: UploadFile = File(...),
    user_id_form: str = Form(None),  # Ignore this, use authenticated user
    grid_size: int = Form(32),
    user_id: str = Depends(verify_api_key)
):
    """Generate 3D model from image - requires API key"""
    logger.info(f"Image generation request from user {user_id}: {file.filename}")
    
    # Your existing image generation code here
    # return generate_image_model(file, user_id, grid_size)
    return {"message": "Image generation endpoint - integrate your existing code here"}

@app.get("/download/{filename}")
async def download_file(
    filename: str,
    user_id: str = Depends(verify_api_key)
):
    """Download generated file - requires API key"""
    # Add user-based file access control here
    # return FileResponse(file_path)
    return {"message": f"Download endpoint for {filename} - integrate your existing code here"}

@app.get("/user/{requested_user_id}/models")
async def list_user_models(
    requested_user_id: str,
    user_id: str = Depends(verify_api_key)
):
    """List user's models - users can only see their own, admin can see all"""
    if user_id != "admin" and user_id != requested_user_id:
        raise HTTPException(status_code=403, detail="Access denied")
    
    # Your existing user models listing code here
    return {"message": f"User models for {requested_user_id}"}

if __name__ == "__main__":
    port = int(os.getenv("PORT", 8000))
    uvicorn.run(app, host="0.0.0.0", port=port)
EOF

# Step 4: Update Dockerfile to include authentication
echo "🐳 Creating Dockerfile with authentication..."

cat > Dockerfile.auth << 'EOF'
FROM python:3.10-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Install additional auth dependencies
RUN pip install google-cloud-secret-manager

# Copy application code
COPY . .
COPY auth_middleware.py .
COPY server_with_auth.py .

# Set environment variables
ENV PYTHONPATH=/app
ENV GCP_PROJECT_ID=${GCP_PROJECT_ID}

# Expose port
EXPOSE 8000

# Run the authenticated server
CMD ["python", "server_with_auth.py"]
EOF

# Step 5: Create deployment script for authenticated version
echo "🚀 Creating authenticated deployment script..."

cat > deploy-auth.sh << 'EOF'
#!/bin/bash
set -e

source config.sh

echo "🚀 Deploying authenticated Point-E server..."

# Build and push authenticated image
docker build -f Dockerfile.auth -t gcr.io/${GCP_PROJECT_ID}/point-e-server:auth .
docker push gcr.io/${GCP_PROJECT_ID}/point-e-server:auth

# Update instance template
gcloud compute instance-templates create point-e-template-auth \
    --machine-type=${MACHINE_TYPE} \
    --accelerator=type=nvidia-l4,count=1 \
    --maintenance-policy=TERMINATE \
    --image=point-e-custom-image \
    --boot-disk-size=150GB \
    --boot-disk-type=pd-ssd \
    --tags=http-server,https-server,point-e-server \
    --scopes=https://www.googleapis.com/auth/devstorage.read_write,https://www.googleapis.com/auth/secretmanager \
    --metadata=startup-script='#!/bin/bash
docker pull gcr.io/'${GCP_PROJECT_ID}'/point-e-server:auth
docker stop point-e-container || true
docker rm point-e-container || true
docker run -d --name point-e-container --gpus all -p 80:8000 \
  -e GCP_PROJECT_ID='${GCP_PROJECT_ID}' \
  -e GCS_BUCKET='${GCS_BUCKET}' \
  gcr.io/'${GCP_PROJECT_ID}'/point-e-server:auth' \
    --project=${GCP_PROJECT_ID}

# Update instance group
gcloud compute instance-groups managed set-instance-template ${INSTANCE_GROUP} \
    --template=point-e-template-auth \
    --zone=${ZONE} \
    --project=${GCP_PROJECT_ID}

# Rolling update
gcloud compute instance-groups managed rolling-action start-update ${INSTANCE_GROUP} \
    --version=template=point-e-template-auth \
    --zone=${ZONE} \
    --project=${GCP_PROJECT_ID}

echo "✅ Authenticated server deployed!"
EOF

chmod +x deploy-auth.sh

# Step 6: Create API key management script
cat > manage-api-keys.sh << 'EOF'
#!/bin/bash
# API Key management script

source config.sh

case "$1" in
    "create")
        echo "Creating new API key for user: $2"
        NEW_KEY=$(openssl rand -hex 32)
        echo "New API key: ${NEW_KEY}"
        
        # Add to existing keys
        EXISTING_KEYS=$(gcloud secrets versions access latest --secret=point-e-user-api-keys --project=${GCP_PROJECT_ID})
        NEW_KEYS="${EXISTING_KEYS}
${NEW_KEY}:$2"
        
        gcloud secrets versions add point-e-user-api-keys \
            --data-file=<(echo -e "${NEW_KEYS}") \
            --project=${GCP_PROJECT_ID}
        
        echo "✅ API key created for user $2"
        ;;
    "list")
        echo "Current API keys:"
        gcloud secrets versions access latest --secret=point-e-user-api-keys --project=${GCP_PROJECT_ID}
        ;;
    "revoke")
        echo "To revoke a key, edit the secret manually or recreate it without the unwanted key"
        ;;
    *)
        echo "Usage: $0 {create|list|revoke} [username]"
        echo "  create <username> - Create new API key for user"
        echo "  list              - List all API keys"
        echo "  revoke            - Instructions for revoking keys"
        ;;
esac
EOF

chmod +x manage-api-keys.sh

echo ""
echo "✅ Authentication setup completed!"
echo ""
echo "📋 Files created:"
echo "- auth_middleware.py (authentication logic)"
echo "- server_with_auth.py (authenticated server template)"
echo "- Dockerfile.auth (Docker image with auth)"
echo "- deploy-auth.sh (deployment script)"
echo "- manage-api-keys.sh (API key management)"
echo ""
echo "🔑 API Keys created:"
echo "- Master key: ${MASTER_API_KEY}"
echo "- User 1 key: ${USER_API_KEY_1}"
echo "- User 2 key: ${USER_API_KEY_2}"
echo ""
echo "📝 Next steps:"
echo "1. Integrate server_with_auth.py with your existing server.py code"
echo "2. Test authentication locally"
echo "3. Run ./deploy-auth.sh to deploy authenticated version"
echo "4. Update your client applications to include API keys"
echo ""
echo "📖 Usage example:"
echo "curl -X POST https://your-domain.com/generate/text \\"
echo "  -H 'Authorization: Bearer ${USER_API_KEY_1}' \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"prompt\": \"a red car\"}'"
