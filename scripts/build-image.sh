#!/bin/bash
# Build Production Point-E Image with Pre-cached Models

set -e

# Configuration - set these environment variables or update here
PROJECT_ID="${GCP_PROJECT_ID:-your-project-id}"
IMAGE_NAME="gcr.io/${PROJECT_ID}/point-e-server"

echo "================================================"
echo "Project: $PROJECT_ID"
echo "Image: $IMAGE_NAME:production"
echo ""

echo "🏗️ Building production image with pre-cached models..."
echo "   This downloads 5GB+ models ONCE during build (not at runtime)"
echo "   Future pod starts will be <15 seconds!"
echo ""

# Build the production image
docker build -t $IMAGE_NAME:production .

echo ""
echo "📤 Configuring Docker for Google Container Registry..."

# Configure docker for GCR
gcloud auth configure-docker --quiet 2>/dev/null || echo "   Docker already configured"

echo "📤 Pushing production image to GCR..."
echo "   This may take 5-10 minutes for the large image..."

# Push to GCR
if docker push $IMAGE_NAME:production; then
    echo ""
    echo "✅ SUCCESS! Production image ready!"
    echo "=================================="
    echo ""
    echo "🎯 Your optimized image: $IMAGE_NAME:production"
    echo "   • Models pre-cached (5GB+ models included)"
    echo "   • Pod startup: ~10-15 seconds (not 5+ minutes)"
    echo "   • Ready for instant autoscaling"
    echo ""
    echo "📋 NEXT STEPS - Deploy to GKE:"
    echo "1. In Google Cloud Console, enable these APIs:"
    echo "   • Kubernetes Engine API"
    echo "   • Container Registry API"
    echo ""
    echo "2. Create GKE cluster:"
    echo "   gcloud container clusters create point-e-production \\"
    echo "     --zone=us-central1-a \\"
    echo "     --machine-type=g2-standard-8 \\"
    echo "     --accelerator=type=nvidia-l4,count=1 \\"
    echo "     --num-nodes=2 \\"
    echo "     --enable-autoscaling \\"
    echo "     --min-nodes=1 \\"
    echo "     --max-nodes=10"
    echo ""
    echo "3. Deploy your app:"
    echo "   kubectl apply -f k8s-production.yaml"
    echo ""
    echo "🎮 Ready for your Godot AI chat integration!"
else
    echo ""
    echo "❌ Push failed. Trying alternative approach..."
    echo ""
    echo "💡 Manual deployment option:"
    echo "1. Export image: docker save $IMAGE_NAME:production > point-e-production.tar"
    echo "2. Upload to your GKE cluster nodes"
    echo "3. Import: docker load < point-e-production.tar"
fi


