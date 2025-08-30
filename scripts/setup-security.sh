#!/bin/bash
# Security setup script for Point-E server
# Run this after your initial deployment to add security layers

set -e

# Load configuration
if [[ ! -f "config.sh" ]]; then
    echo "❌ config.sh not found. Copy from config.sh.example and configure it first."
    exit 1
fi

source config.sh

echo "🔒 Setting up security for Point-E server..."
echo "Project: ${GCP_PROJECT_ID}"
echo "Region: ${REGION}"

# Step 1: Reserve a static IP for SSL certificate
echo "📍 Reserving static IP address..."
gcloud compute addresses create point-e-static-ip \
    --global \
    --project=${GCP_PROJECT_ID} || echo "IP already exists"

STATIC_IP=$(gcloud compute addresses describe point-e-static-ip --global --format="value(address)")
echo "Static IP: ${STATIC_IP}"

# Update config.sh with the static IP
if ! grep -q "STATIC_IP" config.sh; then
    echo "export STATIC_IP=\"${STATIC_IP}\"" >> config.sh
fi

# Step 2: Create SSL certificate (requires domain)
echo "🔐 SSL Certificate Setup"
echo "⚠️  You need a domain name for SSL. Options:"
echo "1. Use Google-managed certificate (requires domain)"
echo "2. Use self-signed certificate (for testing)"
echo "3. Skip SSL setup for now"
read -p "Choose option (1/2/3): " ssl_option

case $ssl_option in
    1)
        read -p "Enter your domain name (e.g., api.yoursite.com): " DOMAIN_NAME
        echo "Creating managed SSL certificate for ${DOMAIN_NAME}..."
        
        gcloud compute ssl-certificates create point-e-ssl-cert \
            --domains=${DOMAIN_NAME} \
            --global \
            --project=${GCP_PROJECT_ID} || echo "Certificate already exists"
        
        echo "export DOMAIN_NAME=\"${DOMAIN_NAME}\"" >> config.sh
        SSL_CERT="point-e-ssl-cert"
        ;;
    2)
        echo "Creating self-signed certificate..."
        SSL_CERT="point-e-self-signed"
        # Note: Self-signed certs need to be uploaded separately
        echo "⚠️  You'll need to create and upload a self-signed certificate"
        ;;
    3)
        echo "⚠️  Skipping SSL setup. Your API will be HTTP only (not recommended for production)"
        SSL_CERT=""
        ;;
esac

# Step 3: Update load balancer to use HTTPS
if [[ -n "$SSL_CERT" ]]; then
    echo "🌐 Updating load balancer for HTTPS..."
    
    # Create HTTPS proxy
    gcloud compute target-https-proxies create point-e-https-proxy \
        --url-map=point-e-map \
        --ssl-certificates=${SSL_CERT} \
        --global \
        --project=${GCP_PROJECT_ID} || echo "HTTPS proxy already exists"
    
    # Create HTTPS forwarding rule
    gcloud compute forwarding-rules create point-e-https-rule \
        --global \
        --target-https-proxy=point-e-https-proxy \
        --address=point-e-static-ip \
        --ports=443 \
        --project=${GCP_PROJECT_ID} || echo "HTTPS rule already exists"
    
    # Update HTTP rule to redirect to HTTPS
    echo "🔄 Setting up HTTP to HTTPS redirect..."
    
    # Create redirect URL map
    gcloud compute url-maps create point-e-redirect-map \
        --default-backend-service=point-e-backend \
        --global \
        --project=${GCP_PROJECT_ID} || echo "Redirect map already exists"
    
    # Add redirect rule
    gcloud compute url-maps add-path-matcher point-e-redirect-map \
        --path-matcher-name=redirect-matcher \
        --default-backend-service=point-e-backend \
        --global || echo "Path matcher already exists"
fi

# Step 4: Set up Cloud Armor for DDoS protection
echo "🛡️  Setting up Cloud Armor security policy..."

gcloud compute security-policies create point-e-security-policy \
    --description="Security policy for Point-E API" \
    --project=${GCP_PROJECT_ID} || echo "Security policy already exists"

# Add rate limiting rule
gcloud compute security-policies rules create 1000 \
    --security-policy=point-e-security-policy \
    --expression="true" \
    --action="rate-based-ban" \
    --rate-limit-threshold-count=100 \
    --rate-limit-threshold-interval-sec=60 \
    --ban-duration-sec=600 \
    --conform-action=allow \
    --exceed-action=deny-429 \
    --enforce-on-key=IP \
    --project=${GCP_PROJECT_ID} || echo "Rate limit rule already exists"

# Apply security policy to backend service
gcloud compute backend-services update point-e-backend \
    --security-policy=point-e-security-policy \
    --global \
    --project=${GCP_PROJECT_ID}

# Step 5: Configure firewall rules
echo "🔥 Setting up firewall rules..."

# Allow HTTPS traffic
gcloud compute firewall-rules create allow-point-e-https \
    --allow tcp:443 \
    --source-ranges 0.0.0.0/0 \
    --target-tags https-server \
    --description="Allow HTTPS traffic to Point-E" \
    --project=${GCP_PROJECT_ID} || echo "HTTPS firewall rule already exists"

# Allow HTTP for health checks and redirects
gcloud compute firewall-rules create allow-point-e-http \
    --allow tcp:80 \
    --source-ranges 130.211.0.0/22,35.191.0.0/16 \
    --target-tags http-server \
    --description="Allow HTTP for load balancer health checks" \
    --project=${GCP_PROJECT_ID} || echo "HTTP firewall rule already exists"

# Deny direct access to instances (only allow through load balancer)
gcloud compute firewall-rules create deny-point-e-direct \
    --action deny \
    --rules tcp:8000 \
    --source-ranges 0.0.0.0/0 \
    --target-tags point-e-server \
    --description="Deny direct access to Point-E instances" \
    --priority 900 \
    --project=${GCP_PROJECT_ID} || echo "Deny rule already exists"

# Step 6: Update instance template with security tags
echo "🏷️  Updating instance template with security tags..."

gcloud compute instance-templates create point-e-template-secure \
    --machine-type=${MACHINE_TYPE} \
    --accelerator=type=nvidia-l4,count=1 \
    --maintenance-policy=TERMINATE \
    --image=point-e-custom-image \
    --boot-disk-size=150GB \
    --boot-disk-type=pd-ssd \
    --tags=http-server,https-server,point-e-server \
    --scopes=https://www.googleapis.com/auth/devstorage.read_write \
    --project=${GCP_PROJECT_ID} || echo "Secure template already exists"

# Update instance group to use new template
echo "🔄 Updating instance group..."
gcloud compute instance-groups managed set-instance-template ${INSTANCE_GROUP} \
    --template=point-e-template-secure \
    --zone=${ZONE} \
    --project=${GCP_PROJECT_ID}

# Rolling update to apply new template
gcloud compute instance-groups managed rolling-action start-update ${INSTANCE_GROUP} \
    --version=template=point-e-template-secure \
    --zone=${ZONE} \
    --project=${GCP_PROJECT_ID}

echo ""
echo "✅ Security setup completed!"
echo ""
echo "📊 Summary:"
echo "- Static IP: ${STATIC_IP}"
if [[ -n "$DOMAIN_NAME" ]]; then
    echo "- Domain: ${DOMAIN_NAME}"
    echo "- SSL Certificate: Enabled"
    echo "- HTTPS URL: https://${DOMAIN_NAME}"
else
    echo "- HTTPS URL: https://${STATIC_IP}"
fi
echo "- Cloud Armor: Enabled (100 requests/minute per IP)"
echo "- Firewall: Configured"
echo ""
echo "🔄 Next steps:"
if [[ -n "$DOMAIN_NAME" ]]; then
    echo "1. Point your domain ${DOMAIN_NAME} to IP ${STATIC_IP}"
    echo "2. Wait for SSL certificate to be provisioned (can take 15-60 minutes)"
fi
echo "3. Test your API: curl https://${DOMAIN_NAME:-$STATIC_IP}/health"
echo "4. Update your applications to use HTTPS URLs"
echo ""
echo "⚠️  Important: Update config.sh with the new HTTPS URL!"
