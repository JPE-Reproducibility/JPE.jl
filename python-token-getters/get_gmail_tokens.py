# get_gmail_tokens.py

import os
import json
from google_auth_oauthlib.flow import InstalledAppFlow


# Define the required Gmail scopes
SCOPES = ['https://www.googleapis.com/auth/gmail.send', 'https://www.googleapis.com/auth/gmail.compose']

# Load secrets from environment variables
DROPBOX = os.environ["JPE_DBOX"]

def get_tokens():
    # Load credentials from a client_secret JSON file (from Google Cloud Console)
    flow = InstalledAppFlow.from_client_secrets_file(
        os.path.join(DROPBOX,'keys','jpe-gmail-client.json'), SCOPES
    )

    # Run the flow and get credentials
    creds = flow.run_local_server(port=0)

    print("\n✅ SUCCESS! Here are your tokens:\n")
    print(f"ACCESS_TOKEN={creds.token}")
    print(f"REFRESH_TOKEN={creds.refresh_token}")
    print(f"TOKEN_URI={creds.token_uri}")
    print(f"CLIENT_ID={creds.client_id}")
    print(f"CLIENT_SECRET={creds.client_secret}")

    # Save to a file (optional)
    with open(os.path.join(DROPBOX,"keys","gmail_tokens.json"), "w") as f:
        json.dump({
            "ACCESS_TOKEN": creds.token,
            "REFRESH_TOKEN": creds.refresh_token,
            "TOKEN_URI": creds.token_uri,
            "CLIENT_ID": creds.client_id,
            "CLIENT_SECRET": creds.client_secret,
        }, f, indent=2)

if __name__ == "__main__":
    get_tokens()
