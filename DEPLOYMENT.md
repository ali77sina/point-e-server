# Point-E Google Cloud Deployment Guide

This guide walks through deploying Point-E on Google Cloud Platform with GPU acceleration and auto-scaling.

## Prerequisites

- Google Cloud account with billing enabled
- `gcloud` CLI installed and authenticated
- Docker installed locally
- GPU quota in your desired region (L4 GPUs recommended)

## Step 1: Initial Setup

1. **Clone the repository**:
   ```bash
   git clone https://github.com/YOUR_USERNAME/point-e-server.git
   cd point-e-server
   ```

2. **Configure your deployment**:
   ```bash
   cp config.sh.example config.sh
   # Edit config.sh with your project details
   source config.sh
   ```

3. **Enable required APIs**:
   ```bash
   gcloud services enable compute.googleapis.com
   gcloud services enable containerregistry.googleapis.com
   gcloud services enable storage-api.googleapis.com
   ```

## Step 2: Build and Push Docker Image

```bash
./scripts/build-image.sh
```

This will:
- Build the Docker image with pre-cached Point-E models (5GB+)
- Push to Google Container Registry
- Models are downloaded during build, not runtime (fast startup)

## Step 3: Create Custom VM Image

1. **Create a base VM with GPU**:
   ```bash
   gcloud compute instances create point-e-base \
     --machine-type=g2-standard-8 \
     --accelerator=type=nvidia-l4,count=1 \
     --maintenance-policy=TERMINATE \
     --image-family=ubuntu-2204-lts \
     --image-project=ubuntu-os-cloud \
     --boot-disk-size=150GB \
     --boot-disk-type=pd-ssd \
     --zone=${ZONE}
   ```

2. **Install dependencies and create custom image**:
   - SSH into the VM and install NVIDIA drivers
   - Install Docker and nvidia-container-toolkit
   - Pull your Point-E image
   - Create a custom image from this VM

## Step 4: Create Instance Template

```bash
gcloud compute instance-templates create point-e-template \
  --machine-type=g2-standard-8 \
  --accelerator=type=nvidia-l4,count=1 \
  --maintenance-policy=TERMINATE \
  --image=YOUR_CUSTOM_IMAGE \
  --boot-disk-size=150GB \
  --boot-disk-type=pd-ssd \
  --tags=http-server \
  --scopes=https://www.googleapis.com/auth/devstorage.read_write
```

## Step 5: Create Instance Group

```bash
# Create managed instance group
gcloud compute instance-groups managed create ${INSTANCE_GROUP} \
  --base-instance-name=point-e \
  --template=point-e-template \
  --size=1 \
  --zone=${ZONE}

# Configure auto-scaling
gcloud compute instance-groups managed set-autoscaling ${INSTANCE_GROUP} \
  --zone=${ZONE} \
  --max-num-replicas=${MAX_REPLICAS} \
  --min-num-replicas=${MIN_REPLICAS} \
  --target-cpu-utilization=0.6
```

## Step 6: Set Up Load Balancer

```bash
# Create health check
gcloud compute health-checks create http point-e-health \
  --port=80 \
  --request-path=/health

# Create backend service
gcloud compute backend-services create point-e-backend \
  --protocol=HTTP \
  --health-checks=point-e-health \
  --global

# Add instance group to backend
gcloud compute backend-services add-backend point-e-backend \
  --instance-group=${INSTANCE_GROUP} \
  --instance-group-zone=${ZONE} \
  --global

# Create URL map
gcloud compute url-maps create point-e-map \
  --default-service=point-e-backend

# Create HTTP proxy
gcloud compute target-http-proxies create point-e-proxy \
  --url-map=point-e-map

# Create forwarding rule
gcloud compute forwarding-rules create point-e-rule \
  --global \
  --target-http-proxy=point-e-proxy \
  --ports=80
```

## Step 7: Configure Google Cloud Storage

```bash
# Create bucket for storing generated models
gsutil mb -p ${GCP_PROJECT_ID} gs://${GCS_BUCKET}

# Set CORS policy
cat > cors.json <<EOF
[
  {
    "origin": ["*"],
    "method": ["GET", "HEAD"],
    "responseHeader": ["Content-Type"],
    "maxAgeSeconds": 3600
  }
]
EOF
gsutil cors set cors.json gs://${GCS_BUCKET}
```

## Step 8: Deploy Updates

After making code changes, use the update script:

```bash
./scripts/update-point-e.sh
```

This will:
- Build and push new Docker image
- Update all running instances
- Maintain zero downtime

## Testing

```bash
# Get load balancer IP
LOAD_BALANCER_IP=$(gcloud compute forwarding-rules describe point-e-rule --global --format="value(IPAddress)")

# Test generation
curl -X POST http://${LOAD_BALANCER_IP}/generate/text \
  -H "Content-Type: application/json" \
  -d '{"prompt": "a red chair", "user_id": "test-user"}'
```

## Monitoring

- **View instances**: 
  ```bash
  gcloud compute instances list --filter="name:point-e-*"
  ```
- **Check logs**: 
  ```bash
  gcloud compute ssh INSTANCE_NAME --command="sudo docker logs point-e"
  ```
- **View storage**: 
  ```bash
  gsutil ls -r gs://${GCS_BUCKET}
  ```

## Cost Optimization

- Use preemptible instances for development
- Set appropriate auto-scaling limits
- Configure lifecycle rules on GCS bucket
- Monitor GPU utilization

## Troubleshooting

### GPU not detected
- Ensure instance has GPU attached
- Check NVIDIA drivers are installed
- Verify Docker GPU runtime is configured

### Storage permissions
- Check instance has storage.read_write scope
- Verify service account has GCS permissions

### Slow startup
- Use custom VM image with pre-installed dependencies
- Ensure Docker image has pre-cached models
