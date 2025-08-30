#!/bin/bash
# Update Point-E deployment with new code changes
# Safe for open source - all sensitive data comes from config.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Point-E Update Script${NC}"
echo "================================"

# Load configuration
if [ -f config.sh ]; then
    source config.sh
else
    echo -e "${RED}❌ Error: config.sh not found!${NC}"
    echo "Please create config.sh from config.sh.example:"
    echo "  cp config.sh.example config.sh"
    echo "  # Edit config.sh with your project details"
    exit 1
fi

# Validate required variables
if [ -z "$GCP_PROJECT_ID" ]; then
    echo -e "${RED}❌ Error: GCP_PROJECT_ID not set in config.sh${NC}"
    exit 1
fi

# Set defaults
IMAGE_NAME="gcr.io/${GCP_PROJECT_ID}/point-e-server"
INSTANCE_GROUP="${INSTANCE_GROUP:-point-e-fast-autoscale}"
ZONE="${ZONE:-us-central1-a}"
GCS_BUCKET="${GCS_BUCKET:-point-e-3d-models}"

echo "Project: $GCP_PROJECT_ID"
echo "Image: $IMAGE_NAME:production"
echo "Instance Group: $INSTANCE_GROUP"
echo "GCS Bucket: $GCS_BUCKET"
echo ""

# Step 1: Build Docker image
echo -e "${YELLOW}📦 Building Docker image...${NC}"
docker build -t ${IMAGE_NAME}:production .

# Step 2: Push to Container Registry
echo -e "${YELLOW}📤 Pushing to Container Registry...${NC}"
docker push ${IMAGE_NAME}:production

# Step 3: Update instances (if instance group exists)
if gcloud compute instance-groups managed describe ${INSTANCE_GROUP} --zone=${ZONE} &>/dev/null; then
    echo -e "${YELLOW}🔄 Updating instances...${NC}"
    
    # Get current instances
    INSTANCES=$(gcloud compute instance-groups managed list-instances ${INSTANCE_GROUP} \
        --zone=${ZONE} --format="value(NAME)")
    
    if [ -z "$INSTANCES" ]; then
        echo -e "${YELLOW}No instances found in the group${NC}"
    else
        for INSTANCE in $INSTANCES; do
            echo "Updating instance: $INSTANCE"
            
            # SSH and update
            gcloud compute ssh $INSTANCE --zone=${ZONE} --command="
                # Authenticate Docker
                gcloud auth print-access-token | sudo docker login -u oauth2accesstoken --password-stdin gcr.io
                
                # Pull new image
                sudo docker pull ${IMAGE_NAME}:production
                
                # Restart container
                sudo docker stop point-e || true
                sudo docker rm point-e || true
                
                # Start with environment variables including auth
                sudo docker run -d --name point-e --gpus all -p 80:8000 \
                    -e NVIDIA_VISIBLE_DEVICES=all \
                    -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
                    -e GOOGLE_CLOUD_PROJECT=${GCP_PROJECT_ID} \
                    -e GCS_BUCKET=${GCS_BUCKET} \
                    -e ENABLE_GCS=true \
                    -e POINT_E_SECRET_KEY='${POINT_E_SECRET_KEY}' \
                    -e RATE_LIMIT_PER_IP=${RATE_LIMIT_PER_IP} \
                    -e RATE_LIMIT_WINDOW=${RATE_LIMIT_WINDOW} \
                    ${IMAGE_NAME}:production
                
                echo 'Instance updated!'
            " || echo -e "${YELLOW}⚠️  Failed to update $INSTANCE, continuing...${NC}"
        done
    fi
else
    echo -e "${YELLOW}⚠️  No instance group found. Image pushed to registry.${NC}"
    echo "To deploy, run the deployment script first."
fi

echo ""
echo -e "${GREEN}✅ Update complete!${NC}"
echo ""
echo "Test your deployment:"
echo "  curl -X POST http://${LOAD_BALANCER_IP}/generate/text \\"
echo "    -H \"Authorization: Bearer \${POINT_E_SECRET_KEY}\" \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -H \"X-Forwarded-For: 1.2.3.4\" \\"
echo "    -d '{\"prompt\": \"a golden trophy\"}'"
