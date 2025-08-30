#!/usr/bin/env python3
"""
Quick API test for Point-E server
"""

import requests
import time

def test_server():
    api_url = "http://localhost:8000"
    
    print("🧪 Testing Point-E Server")
    print("=" * 40)
    
    # Health check
    try:
        response = requests.get(f"{api_url}/health", timeout=10)
        if response.status_code == 200:
            result = response.json()
            print("✅ Server running!")
            print(f"   Author: {result.get('author', 'Unknown')}")
            print(f"   Models: {result.get('models_loaded', False)}")
        else:
            print("❌ Health check failed")
            return
    except Exception as e:
        print(f"❌ Server not running: {e}")
        print("💡 Start server: python server.py")
        return
    
    # Test text generation
    print("\n🎯 Testing text-to-3D...")
    try:
        response = requests.post(
            f"{api_url}/generate/text",
            json={"prompt": "a blue cube", "format": "mesh", "grid_size": 32},
            timeout=120
        )
        
        if response.status_code == 200:
            result = response.json()
            print("✅ Text generation successful!")
            print(f"   Message: {result['message']}")
            print(f"   Vertices: {result.get('vertices', 'N/A')}")
            print(f"   Download: {result.get('file_url', 'N/A')}")
        else:
            print(f"❌ Text generation failed: {response.status_code}")
            print(f"   Error: {response.text}")
    except Exception as e:
        print(f"❌ Test failed: {e}")

if __name__ == "__main__":
    test_server()


