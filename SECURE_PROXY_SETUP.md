# Secure Proxy Setup for Point-E Server

This guide explains how to set up secure communication between your main server and the Point-E server using shared secret authentication and IP-based rate limiting.

## Configuration

### 1. Set Environment Variables

On your Point-E server, set these environment variables:

```bash
# Required: Shared secret key (must match on both servers)
export POINT_E_SECRET_KEY="your-very-long-secure-random-key-here"

# Optional: Rate limiting configuration
export RATE_LIMIT_PER_IP="5"        # Max generations per IP per day
export RATE_LIMIT_WINDOW="86400"    # Time window in seconds (24 hours)

# Your existing config
export GCS_BUCKET="point-e-3d-models"
export GCP_PROJECT_ID="your-project-id"
```

### 2. Generate a Secure Key

Generate a strong random key:

```bash
# Generate a 32-byte random key
openssl rand -hex 32
```

## How It Works

1. **Authentication**: All requests must include the secret key in the Authorization header
2. **IP Forwarding**: Your main server forwards the original user's IP
3. **Rate Limiting**: Each forwarded IP gets 5 generations per day

## API Usage from Your Main Server

### Text Generation Example

```python
import requests

# Your configuration
POINT_E_URL = "http://YOUR_POINT_E_SERVER_IP"  # Your Point-E server
SECRET_KEY = "your-very-long-secure-random-key-here"

def generate_3d_from_text(prompt, user_ip, user_id=None):
    headers = {
        "Authorization": f"Bearer {SECRET_KEY}",
        "X-Forwarded-For": user_ip,  # Forward the original user's IP
        "Content-Type": "application/json"
    }
    
    data = {
        "prompt": prompt,
        "user_id": user_id,
        "grid_size": 32
    }
    
    response = requests.post(
        f"{POINT_E_URL}/generate/text",
        headers=headers,
        json=data
    )
    
    if response.status_code == 429:
        # Rate limit exceeded
        error_data = response.json()
        return {
            "error": "rate_limit",
            "message": f"User has reached the limit of {error_data['detail']['limit']} generations today",
            "reset_time": error_data['detail']['reset_time']
        }
    
    return response.json()

# Example usage
result = generate_3d_from_text(
    prompt="a red sports car",
    user_ip="123.45.67.89",  # The actual end user's IP
    user_id="user123"
)
```

### Image Generation Example

```python
def generate_3d_from_image(image_path, user_ip, user_id=None):
    headers = {
        "Authorization": f"Bearer {SECRET_KEY}",
        "X-Forwarded-For": user_ip
    }
    
    with open(image_path, 'rb') as f:
        files = {'file': f}
        data = {
            'user_id': user_id,
            'grid_size': 32
        }
        
        response = requests.post(
            f"{POINT_E_URL}/generate/image",
            headers=headers,
            files=files,
            data=data
        )
    
    return response.json()
```

### Check Usage for an IP

```python
def check_user_usage(user_ip):
    headers = {
        "Authorization": f"Bearer {SECRET_KEY}"
    }
    
    response = requests.get(
        f"{POINT_E_URL}/usage/{user_ip}",
        headers=headers
    )
    
    return response.json()

# Example: Check how many generations a user has left
usage = check_user_usage("123.45.67.89")
print(f"User has {usage['remaining']} generations left today")
```

## Security Best Practices

1. **Keep the secret key secure**
   - Never commit it to your repository
   - Use environment variables or secret management services
   - Rotate the key periodically

2. **Use HTTPS in production**
   - The secret key is sent in headers, so use HTTPS to encrypt traffic
   - See the security setup scripts for enabling HTTPS

3. **Whitelist your main server IP**
   - Consider adding firewall rules to only allow traffic from your main server
   - Use GCP firewall rules or Cloud Armor

4. **Monitor usage**
   - Check logs for suspicious patterns
   - Monitor rate limit violations

## Headers Reference

| Header | Purpose | Example |
|--------|---------|---------|
| `Authorization` | Shared secret authentication | `Bearer your-secret-key` |
| `X-Forwarded-For` | Original user's IP address | `123.45.67.89` |
| `X-Real-IP` | Alternative IP header | `123.45.67.89` |
| `X-Original-IP` | Another alternative | `123.45.67.89` |

## Rate Limiting

- Default: 5 generations per IP per 24 hours
- Resets at midnight UTC
- Returns 429 status code when exceeded
- Response includes reset time and remaining count

## Troubleshooting

### 401 Unauthorized
- Check that the secret key matches on both servers
- Ensure the Authorization header format is correct: `Bearer YOUR_KEY`

### 429 Rate Limit Exceeded
- The forwarded IP has used all available generations
- Check the response for reset time
- Use the `/usage/{ip}` endpoint to check current usage

### 503 Service Unavailable
- The Point-E models are still loading
- Wait a few minutes and retry
- Check the `/health` endpoint
