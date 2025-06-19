import os
import webbrowser
import http.server
import requests
import threading

import urllib.parse
from urllib.parse import urlparse, parse_qs, quote


APP_KEY = os.environ["JPE_DBOX_APP"]
APP_SECRET = os.environ["JPE_DBOX_APP_SECRET"]
REDIRECT_URI = 'http://localhost:53682'  # you need to set that URI on the dropbox UI for the app

# Step 1: Build authorization URL
scopes = "file_requests.write file_requests.write files.content.write files.content.read files.metadata.read"
scope_param = urllib.parse.quote(scopes)

auth_url = (
    f"https://www.dropbox.com/oauth2/authorize"
    f"?client_id={APP_KEY}"
    f"&redirect_uri={REDIRECT_URI}"
    f"&response_type=code"
    f"&token_access_type=offline"
    f"&scope={scope_param}"
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
