import os
import webbrowser
import http.server
import requests
import threading
from urllib.parse import urlparse, parse_qs

APP_KEY = 'l5g60uc0i2yn2iw'
APP_SECRET = '0b2zxcxogohm5ag'
REDIRECT_URI = 'http://localhost:53682'

# Step 1: Build authorization URL
auth_url = (
    f"https://www.dropbox.com/oauth2/authorize"
    f"?client_id={APP_KEY}"
    f"&redirect_uri={REDIRECT_URI}"
    f"&response_type=code"
    f"&token_access_type=offline"
)

# Step 2: Create temporary HTTP server to catch the redirect
class OAuthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"You can close this window.")
        code = parse_qs(urlparse(self.path).query).get("code")
        if code:
            self.server.auth_code = code[0]

def get_auth_code():
    server = http.server.HTTPServer(('localhost', 53682), OAuthHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    webbrowser.open(auth_url)
    print("Waiting for Dropbox authorization...")
    while not hasattr(server, 'auth_code'):
        pass
    server.shutdown()
    return server.auth_code

# Step 3: Exchange code for refresh token
def get_refresh_token(code):
    token_url = "https://api.dropbox.com/oauth2/token"
    response = requests.post(
        token_url,
        data={
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": REDIRECT_URI,
        },
        auth=(APP_KEY, APP_SECRET),
    )
    response.raise_for_status()
    return response.json()["refresh_token"]

if __name__ == "__main__":
    code = get_auth_code()
    refresh_token = get_refresh_token(code)
    print("\n🎉 Your Dropbox Refresh Token:\n")
    print(refresh_token)
