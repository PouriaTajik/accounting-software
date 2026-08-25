"""Hosted / on-prem entry point.

Multi-tenant deployment of the exact same app the desktop build runs as a
local subprocess. The only difference is configuration.

    uvicorn apps.server.main:app --host 0.0.0.0 --port 8000
"""

from accounting_api.config import DeploymentMode, Settings
from accounting_api.main import create_app

settings = Settings(deployment_mode=DeploymentMode.SERVER)

app = create_app(settings)
