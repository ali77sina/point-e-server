#!/bin/bash
# Quick deployment of authentication update

set -e

# Load configuration
source config.sh

echo "🔐 Quick deploy authentication to Point-E server..."
echo ""

# Option 1: For immediate testing (SSH into instances)
echo "📋 Option 1: Quick test (SSH into an instance):"
echo "---------------------------------------------"
echo "1. SSH into one of your instances:"
echo "   gcloud compute ssh point-e-XXXXX --zone=${ZONE}"
echo ""
echo "2. Set environment variables and restart container:"
echo "   export POINT_E_SECRET_KEY='${POINT_E_SECRET_KEY}'"
echo "   export RATE_LIMIT_PER_IP=${RATE_LIMIT_PER_IP}"
echo "   export RATE_LIMIT_WINDOW=${RATE_LIMIT_WINDOW}"
echo "   docker restart point-e-container"
echo ""

# Option 2: Proper deployment
echo "📋 Option 2: Full deployment (recommended):"
echo "-------------------------------------------"
echo "1. Build and push new Docker image:"
echo "   ./scripts/build-image.sh"
echo ""
echo "2. Update all instances:"
echo "   ./scripts/update-point-e.sh"
echo ""

# Test command
echo "🧪 Test authentication after deployment:"
echo "----------------------------------------"
echo "# Test without auth (should fail with 401):"
echo "curl -X POST http://${LOAD_BALANCER_IP}/generate/text \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -H 'X-Forwarded-For: 1.2.3.4' \\"
echo "  -d '{\"prompt\": \"a red car\"}'"
echo ""
echo "# Test with auth (should work):"
echo "curl -X POST http://${LOAD_BALANCER_IP}/generate/text \\"
echo "  -H 'Authorization: Bearer ${POINT_E_SECRET_KEY}' \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -H 'X-Forwarded-For: 1.2.3.4' \\"
echo "  -d '{\"prompt\": \"a red car\"}'"
echo ""
echo "# Check rate limit usage:"
echo "curl -X GET http://${LOAD_BALANCER_IP}/usage/1.2.3.4 \\"
echo "  -H 'Authorization: Bearer ${POINT_E_SECRET_KEY}'"
