# gmail_client.py

import os
import base64
from email.message import EmailMessage
from googleapiclient.discovery import build
from google.oauth2.credentials import Credentials

def _build_gmail_service():
    """Initialize Gmail API client using access token from environment."""
    access_token = os.getenv("GMAIL_ACCESS_TOKEN")
    if not access_token:
        raise EnvironmentError("Missing GMAIL_ACCESS_TOKEN in environment.")
    creds = Credentials(token=access_token)
    return build("gmail", "v1", credentials=creds)

def _create_email(to, subject, html_body, attachments=None):
    """Creates an EmailMessage with HTML content and optional attachments."""
    sender = os.getenv("GMAIL_USER")
    if not sender:
        raise EnvironmentError("Missing GMAIL_USER in environment.")

    msg = EmailMessage()
    msg["To"] = to
    msg["From"] = sender
    msg["Subject"] = subject
    msg.set_content("This is a plain text fallback.")
    msg.add_alternative(html_body, subtype="html")

    if attachments:
        for file_path in attachments:
            with open(file_path, "rb") as f:
                data = f.read()
                filename = os.path.basename(file_path)
                maintype, subtype = "application", "octet-stream"
                msg.add_attachment(data, maintype=maintype, subtype=subtype, filename=filename)

    return msg

def create_draft_email(to, subject, html_body, attachments=None):
    """
    Creates a draft email in the authenticated user's Gmail account.
    """
    service = _build_gmail_service()
    msg = _create_email(to, subject, html_body, attachments)
    raw = base64.urlsafe_b64encode(msg.as_bytes()).decode()
    body = {"message": {"raw": raw}}
    draft = service.users().drafts().create(userId="me", body=body).execute()
    print(f"Draft created: ID = {draft['id']}")
    return draft

def send_email(to, subject, html_body, attachments=None):
    """
    Sends an email using the Gmail API.
    """
    service = _build_gmail_service()
    msg = _create_email(to, subject, html_body, attachments)
    raw = base64.urlsafe_b64encode(msg.as_bytes()).decode()
    body = {"raw": raw}
    sent = service.users().messages().send(userId="me", body=body).execute()
    print(f"Email sent: ID = {sent['id']}")
    return sent
