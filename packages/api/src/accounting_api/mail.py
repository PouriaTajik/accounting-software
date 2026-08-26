"""Outbound mail: currently just the password-reset link.

Genuinely optional, not a stub -- most installs of this software are a
single desktop machine, where "email a reset link" doesn't make sense
(BUSINESS_PRINCIPLES.md: self-hosted-first, not a hosted-only SaaS). When
`Settings.smtp_host` isn't configured, the message is logged at INFO level
instead of sent -- loud enough for a self-hoster to find without needing a
mail server for day one, and the caller (routers/auth.py) never has to know
which happened.

stdlib `smtplib`/`email.message` rather than a mail-sending dependency:
one plain-text message, no templates, no attachments -- exactly the shape
the stdlib already covers, and pulling in a dependency for it would be the
same mistake this project has deliberately avoided elsewhere (uuid-ossp,
passlib -- see db/README.md's decisions log and core/auth.py).
"""

from __future__ import annotations

import logging
import smtplib
from email.message import EmailMessage
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .config import Settings

logger = logging.getLogger(__name__)


def send_mail(settings: Settings, *, to: str, subject: str, body: str) -> None:
    if not settings.smtp_host:
        logger.info(
            "SMTP not configured; logging instead of sending. To: %s Subject: %s\n%s",
            to,
            subject,
            body,
        )
        return

    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = settings.smtp_from_address
    message["To"] = to
    message.set_content(body)

    with smtplib.SMTP(settings.smtp_host, settings.smtp_port) as server:
        if settings.smtp_use_tls:
            server.starttls()
        if settings.smtp_username:
            server.login(settings.smtp_username, settings.smtp_password or "")
        server.send_message(message)
