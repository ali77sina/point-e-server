#!/bin/bash
# Test authentication on Point-E server

source config.sh

echo "🧪 Testing Point-E Authentication..."
echo "Server: http://${LOAD_BALANCER_IP}"
echo "Rate limit: ${RATE_LIMIT_PER_IP} per IP per day"
echo ""

# Test 1: Without authentication (should fail)
echo "1️⃣ Test without auth (should fail with 401):"
curl -s -o /dev/null -w "Status: %{http_code}\n" \
  -X POST http://${LOAD_BALANCER_IP}/generate/text \
  -H "Content-Type: application/json" \
  -H "X-Forwarded-For: test.ip.1" \
  -d '{"prompt": "test without auth"}'
echo ""

# Test 2: With wrong key (should fail)
echo "2️⃣ Test with wrong key (should fail with 401):"
curl -s -o /dev/null -w "Status: %{http_code}\n" \
  -X POST http://${LOAD_BALANCER_IP}/generate/text \
  -H "Authorization: Bearer wrong-key-12345" \
  -H "Content-Type: application/json" \
  -H "X-Forwarded-For: test.ip.2" \
  -d '{"prompt": "test wrong auth"}'
echo ""

# Test 3: With correct key (should work)
echo "3️⃣ Test with correct key (should work with 200):"
response=$(curl -s -w "\nStatus: %{http_code}" \
  -X POST http://${LOAD_BALANCER_IP}/generate/text \
  -H "Authorization: Bearer ${POINT_E_SECRET_KEY}" \
  -H "Content-Type: application/json" \
  -H "X-Forwarded-For: test.ip.3" \
  -d '{"prompt": "a small red cube"}')
echo "$response" | tail -n 1
echo ""

# Test 4: Check rate limit
echo "4️⃣ Check rate limit usage:"
curl -s http://${LOAD_BALANCER_IP}/usage/test.ip.3 \
  -H "Authorization: Bearer ${POINT_E_SECRET_KEY}" | jq .
echo ""

echo "✅ Authentication test complete!"
