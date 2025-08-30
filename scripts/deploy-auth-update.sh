#!/bin/bash
# Deploy authentication update to running Point-E server

set -e

# Load configuration
source config.sh

echo "🔐 Deploying authentication update to Point-E server..."
echo "Instance group: ${INSTANCE_GROUP}"
echo "Zone: ${ZONE}"

# Step 1: Update instance template with new environment variables
echo "📝 Creating new instance template with authentication..."

gcloud compute instance-templates create point-e-template-auth-$(date +%s) \
    --machine-type=${MACHINE_TYPE} \
    --accelerator=type=nvidia-l4,count=1 \
    --maintenance-policy=TERMINATE \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=150GB \
    --boot-disk-type=pd-ssd \
    --tags=http-server,https-server \
    --scopes=https://www.googleapis.com/auth/devstorage.read_write \
    --metadata=startup-script='#!/bin/bash
# Pull and run the Point-E container with auth
docker pull gcr.io/'${GCP_PROJECT_ID}'/point-e-server:latest
docker stop point-e-container || true
docker rm point-e-container || true
docker run -d --name point-e-container --gpus all -p 80:8000 \
  -e GCP_PROJECT_ID='${GCP_PROJECT_ID}' \
  -e GCS_BUCKET='${GCS_BUCKET}' \
  -e POINT_E_SECRET_KEY='${POINT_E_SECRET_KEY}' \
  -e RATE_LIMIT_PER_IP='${RATE_LIMIT_PER_IP}' \
  -e RATE_LIMIT_WINDOW='${RATE_LIMIT_WINDOW}' \
  gcr.io/'${GCP_PROJECT_ID}'/point-e-server:latest' \
    --project=${GCP_PROJECT_ID}

# Step 2: Update instance group to use new template
echo "🔄 Updating instance group..."
TEMPLATE_NAME=$(gcloud compute instance-templates list --filter="name:point-e-template-auth-*" --format="value(name)" --limit=1 --project=${GCP_PROJECT_ID})

gcloud compute instance-groups managed set-instance-template ${INSTANCE_GROUP} \
    --template=${TEMPLATE_NAME} \
    --zone=${ZONE} \
    --project=${GCP_PROJECT_ID}

# Step 3: Rolling update to apply changes
echo "🚀 Starting rolling update..."
gcloud compute instance-groups managed rolling-action start-update ${INSTANCE_GROUP} \
    --version=template=${TEMPLATE_NAME} \
    --zone=${ZONE} \
    --project=${GCP_PROJECT_ID}

echo ""
echo "✅ Authentication deployment started!"
echo ""
echo "🔍 Monitor the update:"
echo "gcloud compute instance-groups managed list-instances ${INSTANCE_GROUP} --zone=${ZONE}"
echo ""
echo "⏳ This will take a few minutes as instances are replaced..."
echo ""
echo "🧪 Test authentication once deployed:"
echo "curl -X POST http://${LOAD_BALANCER_IP}/generate/text \\"
echo "  -H 'Authorization: Bearer ${POINT_E_SECRET_KEY}' \\"
echo "  -H 'X-Forwarded-For: 123.45.67.89' \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"prompt\": \"test authentication\"}'"
