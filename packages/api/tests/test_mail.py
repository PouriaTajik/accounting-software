"""Outbound mail's optional-SMTP fallback.

No real SMTP server: what's worth testing here is the branch a self-hosted
desktop install with no mail server actually takes -- that it logs instead
of silently dropping the message. Sending for real is stdlib smtplib
directly, nothing this package owns to test.
"""

from __future__ import annotations

import logging

import pytest

from accounting_api.config import Settings
from accounting_api.mail import send_mail


def test_logs_the_recipient_and_link_when_smtp_is_not_configured(
    caplog: pytest.LogCaptureFixture,
) -> None:
    settings = Settings(smtp_host=None)
    with caplog.at_level(logging.INFO, logger="accounting_api.mail"):
        send_mail(
            settings,
            to="owner@example.com",
            subject="Reset your password",
            body="link: http://x/y?token=abc",
        )
    assert "owner@example.com" in caplog.text
    assert "token=abc" in caplog.text
