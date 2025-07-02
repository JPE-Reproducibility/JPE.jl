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

def file_request_exists(token, destination_path: str) -> bool:
    dbx = Dropbox(token)

    result = dbx.file_requests_list_v2()
    file_requests = result.file_requests

    while result.has_more:
        result = dbx.file_requests_list_continue(result.cursor)
        file_requests.extend(result.file_requests)

    return any(fr.destination == destination_path for fr in file_requests)



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
    

def check_file_request_submissions(access_token, file_request_id, verbose = False):
    """
    Check if files have been submitted to a specific file request
    
    Args:
        access_token (str): Your Dropbox access token
        file_request_id (str): The ID of the file request
    
    Returns:
        dict: Information about the file request including file count
    """
    dbx = dropbox.Dropbox(access_token)
    
    try:
        # Get file request details including file count
        request_info = dbx.file_requests_get(file_request_id)
        
        if verbose:
            print(f"File Request: {request_info.title}")
            print(f"Status: {'Open' if request_info.is_open else 'Closed'}")
            print(f"Files submitted: {request_info.file_count}")
            print(f"Destination folder: {request_info.destination}")
        
        if hasattr(request_info, 'deadline') and request_info.deadline:
            print(f"Deadline: {request_info.deadline}")
            
        return {
            'title': request_info.title,
            'file_count': request_info.file_count,
            'is_open': request_info.is_open,
            'destination': request_info.destination,
            'request_info': request_info
        }
        
    except dropbox.exceptions.ApiError as e:
        print(f"API Error: {e}")
        return None
    except Exception as e:
        print(f"Error: {e}")
        return None

def monitor_all_file_requests(access_token):
    """
    Check submission status for all file requests
    """
    dbx = dropbox.Dropbox(access_token)
    
    try:
        # Get list of all file requests
        file_requests = dbx.file_requests_list()
        
        print(f"Found {len(file_requests.file_requests)} file requests:")
        
        for request in file_requests.file_requests:
            print(f"\n--- File Request ---")
            print(f"Title: {request.title}")
            print(f"ID: {request.id}")
            print(f"Status: {'Open' if request.is_open else 'Closed'}")
            print(f"Files submitted: {request.file_count}")
            print(f"Destination: {request.destination}")
            
            if request.file_count > 0:
                print(f"✅ Has {request.file_count} submitted files")
            else:
                print("❌ No files submitted yet")
                
    except dropbox.exceptions.ApiError as e:
        print(f"API Error: {e}")
    except Exception as e:
        print(f"Error: {e}")

import dropbox

def cleanup_file_requests(access_token, request_ids_to_delete):
    """
    Delete file requests that are no longer needed
    
    Args:
        access_token (str): Dropbox access token
        request_ids_to_delete (list): List of file request IDs to delete
    """
    if not request_ids_to_delete:
        return
        
    dbx = dropbox.Dropbox(access_token)
    
    for request_id in request_ids_to_delete:
        try:
            # Get request info first
            request_info = dbx.file_requests_get(request_id)
            print(f"🗑️  Deleting file request: '{request_info.title}' (ID: {request_id})")
            
            # Delete the file request - pass as list
            dbx.file_requests_delete([request_id])
            print(f"✅ Successfully deleted file request")
            
        except dropbox.exceptions.ApiError as e:
            print(f"❌ Error deleting file request {request_id}: {e}")
        except Exception as e:
            print(f"❌ Unexpected error: {e}")

def monitor_viable_file_requests(access_token, only_open=True, delete=False):
    """
    Monitor file requests that are viable and optionally clean up problematic ones
    
    Args:
        access_token (str): Dropbox access token
        only_open (bool): Only monitor open file requests
        delete (bool): If True, delete closed requests or requests with missing destination folders
    
    Returns:
        list: List of viable file requests
    """
    dbx = dropbox.Dropbox(access_token)
    
    try:
        file_requests = dbx.file_requests_list()
        viable_requests = []
        closed_request_ids = []
        missing_folder_ids = []
        
        print(f"📋 Processing {len(file_requests.file_requests)} total file requests...")
        
        for request in file_requests.file_requests:
            request_deleted = False
            
            # Check if request is closed
            if not request.is_open:
                print(f"🔒 Found closed request: '{request.title}' (ID: {request.id})")
                closed_request_ids.append(request.id)
                
                if delete:
                    print(f"🗑️  Deleting closed request: '{request.title}'")
                    try:
                        dbx.file_requests_delete([request.id])
                        print(f"✅ Successfully deleted closed request")
                        request_deleted = True
                    except Exception as e:
                        print(f"❌ Error deleting closed request: {e}")
                elif only_open:
                    print(f"⏭️  Skipping closed request (only_open=True)")
                    continue
            
            # Skip further checks if request was deleted
            if request_deleted:
                continue
                
            # Check if destination folder exists (only for non-deleted requests)
            try:
                dbx.files_get_metadata(request.destination)
                # Folder exists, this is a viable request
                if not only_open or request.is_open:
                    viable_requests.append(request)
                    
            except dropbox.exceptions.ApiError as e:
                if hasattr(e.error, 'is_path_not_found') and e.error.is_path_not_found():
                    print(f"📁 Missing destination folder for: '{request.title}' (ID: {request.id})")
                    missing_folder_ids.append(request.id)
                    
                    if delete:
                        print(f"🗑️  Deleting request with missing folder: '{request.title}'")
                        try:
                            dbx.file_requests_delete([request.id])
                            print(f"✅ Successfully deleted request with missing folder")
                        except Exception as delete_error:
                            print(f"❌ Error deleting request with missing folder: {delete_error}")
                    else:
                        print(f"⚠️  Skipping request with missing destination folder")
                elif 'not_found' in str(e).lower() or 'path_not_found' in str(e).lower():
                    # Alternative check for path not found
                    print(f"📁 Missing destination folder for: '{request.title}' (ID: {request.id})")
                    missing_folder_ids.append(request.id)
                    
                    if delete:
                        print(f"🗑️  Deleting request with missing folder: '{request.title}'")
                        try:
                            dbx.file_requests_delete([request.id])
                            print(f"✅ Successfully deleted request with missing folder")
                        except Exception as delete_error:
                            print(f"❌ Error deleting request with missing folder: {delete_error}")
                    else:
                        print(f"⚠️  Skipping request with missing destination folder")
                else:
                    # Some other API error - might still be viable
                    print(f"⚠️  API warning for '{request.title}': {e}")
                    if not only_open or request.is_open:
                        viable_requests.append(request)
        
        # Summary of cleanup actions
        if delete:
            total_deleted = len(closed_request_ids) + len(missing_folder_ids)
            if total_deleted > 0:
                print(f"\n🧹 Cleanup Summary:")
                print(f"   - Closed requests processed: {len(closed_request_ids)}")
                print(f"   - Missing folder requests processed: {len(missing_folder_ids)}")
                print(f"   - Total deletion attempts: {total_deleted}")
        else:
            if closed_request_ids or missing_folder_ids:
                print(f"\n💡 Cleanup Available:")
                if closed_request_ids:
                    print(f"   - {len(closed_request_ids)} closed requests could be deleted")
                if missing_folder_ids:
                    print(f"   - {len(missing_folder_ids)} requests with missing folders could be deleted")
                print(f"   - Run with delete=True to clean up automatically")
        
        print(f"\n📊 Monitoring {len(viable_requests)} viable file requests:")
        
        for request in viable_requests:
            print(f"\n--- {request.title} ---")
            print(f"Status: {'🟢 Open' if request.is_open else '🔴 Closed'}")
            print(f"Files submitted: {request.file_count}")
            print(f"Destination: {request.destination}")
            
            if request.file_count > 0:
                print(f"✅ Has {request.file_count} submission(s)")
            else:
                print("❌ No submissions yet")
        
        return viable_requests
        
    except Exception as e:
        print(f"❌ Error: {e}")
        return []

# Usage examples:
# 
# # Just monitor (default behavior)
# viable_requests = monitor_viable_file_requests(access_token)
# 
# # Monitor and automatically delete closed/problematic requests
# viable_requests = monitor_viable_file_requests(access_token, delete=True)
# 
# # Monitor all requests (including closed ones) but don't delete
# all_viable = monitor_viable_file_requests(access_token, only_open=False, delete=False)
# 
# # Monitor all requests and clean up problematic ones
# cleaned_requests = monitor_viable_file_requests(access_token, only_open=False, delete=True)