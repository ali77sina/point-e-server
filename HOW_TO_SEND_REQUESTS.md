# How to Send Authenticated Requests to Point-E API

## 🔑 Authentication Required

All requests to the Point-E API **MUST** include the secret key in the `Authorization` header.

**Format:** `Authorization: Bearer YOUR_SECRET_KEY`

## 📝 Request Examples

### 1. From Your Main Server (Python)

```python
import requests

# Configuration
POINT_E_URL = "http://34.111.41.245"
SECRET_KEY = "hESgyNKdElzMPbI653ig26eB_PpVAaIn9WU1cE7rYbSIJur6E3PhOaFcyTHiTPKV"

def generate_3d_model(prompt, user_ip):
    """Generate 3D model from text prompt"""
    
    headers = {
        "Authorization": f"Bearer {SECRET_KEY}",  # Required!
        "X-Forwarded-For": user_ip,              # Original user's IP
        "Content-Type": "application/json"
    }
    
    data = {
        "prompt": prompt,
        "grid_size": 32
    }
    
    response = requests.post(
        f"{POINT_E_URL}/generate/text",
        headers=headers,
        json=data
    )
    
    # Handle response
    if response.status_code == 401:
        print("Authentication failed - check your secret key")
    elif response.status_code == 429:
        print(f"Rate limit exceeded for IP {user_ip}")
    elif response.status_code == 200:
        result = response.json()
        print(f"Success! File URL: {result['file_url']}")
    
    return response.json()
```

### 2. Using cURL

```bash
# Text to 3D generation
curl -X POST http://34.111.41.245/generate/text \
  -H "Authorization: Bearer hESgyNKdElzMPbI653ig26eB_PpVAaIn9WU1cE7rYbSIJur6E3PhOaFcyTHiTPKV" \
  -H "Content-Type: application/json" \
  -H "X-Forwarded-For: 123.45.67.89" \
  -d '{
    "prompt": "a red sports car",
    "grid_size": 32
  }'

# Image to 3D generation
curl -X POST http://34.111.41.245/generate/image \
  -H "Authorization: Bearer hESgyNKdElzMPbI653ig26eB_PpVAaIn9WU1cE7rYbSIJur6E3PhOaFcyTHiTPKV" \
  -H "X-Forwarded-For: 123.45.67.89" \
  -F "file=@car.jpg" \
  -F "grid_size=32"

# Check usage for an IP
curl -X GET http://34.111.41.245/usage/123.45.67.89 \
  -H "Authorization: Bearer hESgyNKdElzMPbI653ig26eB_PpVAaIn9WU1cE7rYbSIJur6E3PhOaFcyTHiTPKV"
```

### 3. From Node.js/JavaScript

```javascript
const axios = require('axios');

const POINT_E_URL = 'http://34.111.41.245';
const SECRET_KEY = 'hESgyNKdElzMPbI653ig26eB_PpVAaIn9WU1cE7rYbSIJur6E3PhOaFcyTHiTPKV';

async function generate3DModel(prompt, userIP) {
    try {
        const response = await axios.post(
            `${POINT_E_URL}/generate/text`,
            {
                prompt: prompt,
                grid_size: 32
            },
            {
                headers: {
                    'Authorization': `Bearer ${SECRET_KEY}`,
                    'X-Forwarded-For': userIP,
                    'Content-Type': 'application/json'
                }
            }
        );
        
        console.log('Success:', response.data);
        return response.data;
        
    } catch (error) {
        if (error.response?.status === 401) {
            console.error('Authentication failed - invalid secret key');
        } else if (error.response?.status === 429) {
            console.error('Rate limit exceeded for IP:', userIP);
        }
        throw error;
    }
}
```

### 4. From Godot (GDScript)

```gdscript
var http_request = HTTPRequest.new()
var point_e_url = "http://34.111.41.245"
var secret_key = "hESgyNKdElzMPbI653ig26eB_PpVAaIn9WU1cE7rYbSIJur6E3PhOaFcyTHiTPKV"

func generate_3d_model(prompt: String, user_ip: String):
    var headers = [
        "Authorization: Bearer " + secret_key,
        "Content-Type: application/json",
        "X-Forwarded-For: " + user_ip
    ]
    
    var body = JSON.stringify({
        "prompt": prompt,
        "grid_size": 32
    })
    
    http_request.request(
        point_e_url + "/generate/text",
        headers,
        HTTPClient.METHOD_POST,
        body
    )
```

## ⚠️ Important Notes

1. **Never expose the secret key** to end users or in client-side code
2. **Always proxy requests** through your main server
3. **Rate limit:** Each forwarded IP gets **3 generations per day**
4. **Required headers:**
   - `Authorization: Bearer YOUR_SECRET_KEY` (mandatory)
   - `X-Forwarded-For: user.ip.address` (for rate limiting)
   - `Content-Type: application/json` (for JSON requests)

## 🚫 Common Errors

| Error Code | Meaning | Solution |
|------------|---------|----------|
| 401 | Invalid or missing secret key | Check Authorization header format |
| 429 | Rate limit exceeded | User has used all 3 daily generations |
| 503 | Models not ready | Wait and retry |

## 📊 Check Usage

To check how many generations a user has left:

```bash
curl -X GET http://34.111.41.245/usage/USER_IP_HERE \
  -H "Authorization: Bearer hESgyNKdElzMPbI653ig26eB_PpVAaIn9WU1cE7rYbSIJur6E3PhOaFcyTHiTPKV"
```

Response:
```json
{
  "ip": "123.45.67.89",
  "used": 2,
  "limit": 3,
  "remaining": 1,
  "window_seconds": 86400,
  "reset_time": 1693526400
}
```
