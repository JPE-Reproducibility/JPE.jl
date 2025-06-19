import dropbox
from dropbox.sharing import RequestedVisibility, SharedLinkSettings
import os
import requests
from dropbox import Dropbox

# Load secrets from environment variables
APP_KEY = os.environ["JPE_DBOX_APP"]
APP_SECRET = os.environ["JPE_DBOX_APP_SECRET"]
REFRESH_TOKEN = os.environ["JPE_DBOX_APP_REFRESH"]

def get_access_token():
    url = "https://api.dropbox.com/oauth2/token"
    response = requests.post(
        url,
        auth=(APP_KEY, APP_SECRET),
        data={
            "grant_type": "refresh_token",
            "refresh_token": REFRESH_TOKEN
        }
    )
    response.raise_for_status()
    return response.json()["access_token"]

# Get access token via refresh
access_token = get_access_token()

# Use it with Dropbox SDK
dbx = Dropbox(access_token)

# Test: get current user's account info
account = dbx.users_get_current_account()
print(f"Authenticated as: {account.name.display_name}")
# === Replace with your file path ===
FILE_PATH = "/CASDr"

try:
    # Create settings with 'public' visibility (default for shared links)
    settings = SharedLinkSettings(
        requested_visibility=RequestedVisibility.public
    )

    # Attempt to create a new shared link
    link = dbx.sharing_create_shared_link_with_settings(FILE_PATH, settings)
    print("Public shared link:", link.url)

except dropbox.exceptions.ApiError as e:
    # If a link already exists, list existing links instead
    if isinstance(e.error, dropbox.sharing.CreateSharedLinkWithSettingsError) and e.error.is_shared_link_already_exists():
        links = dbx.sharing_list_shared_links(path=FILE_PATH, direct_only=True)
        if links.links:
            print("Existing public shared link:", links.links[0].url)
        else:
            print("A shared link exists, but we couldn't retrieve it.")
    else:
        print("Error creating shared link:", e)
