#!/usr/bin/env python3
"""
Test production server performance
"""

import requests
import time

def test_production_speed():
    api_url = "http://localhost:8000"
    
    print("⚡ Testing PRODUCTION Point-E Server")
    print("=" * 45)
    
    # Test startup time
    print("🚀 Testing server response time...")
    start = time.time()
    
    try:
        response = requests.get(f"{api_url}/health", timeout=5)
        end = time.time()
        
        if response.status_code == 200:
            result = response.json()
            print(f"✅ Server responded in {end-start:.2f}s")
            print(f"   Models ready: {result.get('models_ready', False)}")
            print(f"   Production: {result.get('production', False)}")
            
            if result.get('models_ready'):
                # Test generation speed
                print("\n⚡ Testing FAST generation (grid_size=32)...")
                gen_start = time.time()
                
                response = requests.post(
                    f"{api_url}/generate/text",
                    json={"prompt": "a red cube", "format": "mesh", "grid_size": 32},
                    timeout=60
                )
                
                gen_end = time.time()
                
                if response.status_code == 200:
                    result = response.json()
                    print(f"✅ Generation completed in {gen_end-gen_start:.1f}s")
                    print(f"   Vertices: {result.get('vertices', 'N/A')}")
                    print(f"   Message: {result['message']}")
                else:
                    print(f"❌ Generation failed: {response.status_code}")
            else:
                print("⏳ Models still loading...")
        else:
            print(f"❌ Health check failed: {response.status_code}")
    except Exception as e:
        print(f"❌ Server not responding: {e}")
        print("💡 Start production server: python server_prod.py")

if __name__ == "__main__":
    test_production_speed()


