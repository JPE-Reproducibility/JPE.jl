import json
import requests
import os

def refresh_access_token_from_json():
    """
    Refresh Gmail access token using a config JSON file with the following fields:
      - ACCESS_TOKEN (optional)
      - REFRESH_TOKEN
      - TOKEN_URI
      - CLIENT_ID
      - CLIENT_SECRET
    Returns the new access token.
    """
    config_path = os.getenv("JPE_GMAIL_TOKEN")
    with open(config_path, "r") as f:
        config = json.load(f)

    refresh_token = config.get("REFRESH_TOKEN")
    client_id = config.get("CLIENT_ID")
    client_secret = config.get("CLIENT_SECRET")
    token_uri = config.get("TOKEN_URI", "https://oauth2.googleapis.com/token")

    if not all([refresh_token, client_id, client_secret]):
        raise ValueError("Missing required fields in the token config JSON.")

    data = {
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh_token,
        "grant_type": "refresh_token"
    }

    response = requests.post(token_uri, data=data)
    if response.status_code != 200:
        raise RuntimeError(f"Failed to refresh access token: {response.text}")

    new_token = response.json()["access_token"]
    
    # Optional: update the JSON file with the new access token
    config["ACCESS_TOKEN"] = new_token
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)

    return new_token
