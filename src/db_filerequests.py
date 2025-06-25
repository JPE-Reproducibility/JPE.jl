import dropbox
from dropbox import Dropbox
from dropbox.file_requests import CreateFileRequestArgs
from dropbox.sharing import RequestedVisibility, SharedLinkSettings
from dropbox.files import FileMetadata
import os
import requests

# Load secrets from environment variables
APP_KEY = os.environ["JPE_DBOX_APP"]
APP_SECRET = os.environ["JPE_DBOX_APP_SECRET"]
REFRESH_TOKEN = os.environ["JPE_DBOX_APP_REFRESH"]

def refresh_token():
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

def get_user_info(token):
        dbx = Dropbox(token)
        return dbx.users_get_current_account()


def get_link_at_path(path,token):
    "get a shareable link for local path /Apps/JPE-packages/path"

    dbx = Dropbox(token)

    try:
        # Create settings with 'public' visibility (default for shared links)
        settings = SharedLinkSettings(
            requested_visibility=RequestedVisibility.public
        )
    
        # Attempt to create a new shared link
        link = dbx.sharing_create_shared_link_with_settings(path, settings)
        print("Public shared link:", link.url)
        return link.url
    
    except dropbox.exceptions.ApiError as e:
        # If a link already exists, list existing links instead
        if isinstance(e.error, dropbox.sharing.CreateSharedLinkWithSettingsError) and e.error.is_shared_link_already_exists():
            links = dbx.sharing_list_shared_links(path=path, direct_only=True)
            if links.links:
                print("Existing public shared link:", links.links[0].url)
                return links.links[0].url
            else:
                print("A shared link exists, but we couldn't retrieve it.")
        else:
            print("Error creating shared link:", e)

def create_file_request(token, title: str, destination_path: str):
    """
    Creates a file request in Dropbox.

    Args:
        token.
        title (str): The title of the file request (visible to users).
        destination_path (str): The Dropbox folder path where uploaded files will be stored.

    Returns:
        the file request objects.
    """
    dbx = Dropbox(token)

    try:
        # Create the file request
        result = dbx.file_requests_create(
            title=title,
            destination=destination_path
        )
        return {'url': result.url, 'id': result.id}
    except dropbox.exceptions.ApiError as e:
        print(f"Dropbox API error: {e}")
        return None



def submission_time(token, destination_path):
    dbx = Dropbox(token)

    try:
        result = dbx.files_list_folder(destination_path)

        for entry in result.entries:
            if isinstance(entry, FileMetadata):
                return entry.server_modified  # First file found

        return None  # No file entries found

    except dropbox.exceptions.ApiError as e:
        print(f"Dropbox API error: {e}")
        return None
    
# if __name__ == "__main__":
#     token = get_access_token()
#     dbx = Dropbox(token)
#     url = create_file_request(dbx, "Upload your documents", "/uploading-tests")
#     if url:
#         print(f"File request created: {url}")
#     else:
#         print("Failed to create file request.")