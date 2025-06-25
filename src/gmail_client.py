import os
import json
import base64
import requests
from googleapiclient.discovery import build
from email.message import EmailMessage
from google.oauth2.credentials import Credentials



def refresh_access_token_from_json():
    """
    Refresh Gmail access token using JSON file path from JPE_GMAIL_TOKEN env var.
    Returns a dictionary with token + client credentials for Gmail API.
    """
    json_path = os.getenv("JPE_GMAIL_TOKEN")
    if not json_path or not os.path.isfile(json_path):
        raise FileNotFoundError("Missing or invalid JPE_GMAIL_TOKEN path.")

    with open(json_path, "r") as f:
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
    config["ACCESS_TOKEN"] = new_token

    # Optionally persist the updated token
    with open(json_path, "w") as f:
        json.dump(config, f, indent=2)

    # Return all needed info to build Credentials
    return {
        "access_token": new_token,
        "refresh_token": refresh_token,
        "client_id": client_id,
        "client_secret": client_secret,
        "token_uri": token_uri
    }



def build_gmail_service():
    token_info = refresh_access_token_from_json()

    creds = Credentials(
        token=token_info["access_token"],
        refresh_token=token_info["refresh_token"],
        token_uri=token_info["token_uri"],
        client_id=token_info["client_id"],
        client_secret=token_info["client_secret"]
    )

    return build("gmail", "v1", credentials=creds)


def send_email(to, subject, html_body, sent_from, attachments=None):
    """
    Send an email with optional attachments.
    """
    service = build_gmail_service()

    msg = EmailMessage()
    msg["To"] = to
    msg["From"] = sent_from
    msg["Subject"] = subject
    msg.set_content("This is a MIME-formatted message.")
    msg.add_alternative(html_body, subtype="html")

    if attachments:
        for file_path in attachments:
            with open(file_path, "rb") as f:
                content = f.read()
                filename = os.path.basename(file_path)
                maintype, subtype = "application", "octet-stream"
                msg.add_attachment(content, maintype=maintype, subtype=subtype, filename=filename)

    encoded_message = base64.urlsafe_b64encode(msg.as_bytes()).decode()
    create_message = {"raw": encoded_message}

    user_id = "me"
    send_result = service.users().messages().send(userId=user_id, body=create_message).execute()
    return send_result


def create_draft(to, subject, html_body, sent_from, attachments=None):
    """
    Create a Gmail draft with optional attachments.
    """
    service = build_gmail_service()

    msg = EmailMessage()
    msg["To"] = to
    msg["From"] = sent_from
    msg["Subject"] = subject
    msg.set_content("This is a MIME-formatted message.")
    msg.add_alternative(html_body, subtype="html")

    if attachments:
        for file_path in attachments:
            with open(file_path, "rb") as f:
                content = f.read()
                filename = os.path.basename(file_path)
                maintype, subtype = "application", "octet-stream"
                msg.add_attachment(content, maintype=maintype, subtype=subtype, filename=filename)

    encoded_message = base64.urlsafe_b64encode(msg.as_bytes()).decode()
    create_message = {"message": {"raw": encoded_message}}

    user_id = "me"
    draft_result = service.users().drafts().create(userId=user_id, body=create_message).execute()
    return draft_result


# testing

# from gmail_client import send_email, create_draft

# send_email(
#     to="florian.oswald@gmail.com",
#     subject="Test Email",
#     html_body="<h1>Hello from Python</h1> you are the man 🚨",
#     attachments=["database.md"]
# )

# create_draft(
#     to="you@example.com",
#     subject="Draft Email",
#     html_body="<p>This is a draft email.</p>"
# )