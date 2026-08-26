"""Runtime configuration.

The same settings object serves both deployment targets. `DEPLOYMENT_MODE`
distinguishes them, and it is the only thing that should ever branch on where
the process is running — never business logic.
"""

from enum import Enum
from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class DeploymentMode(str, Enum):
    #: Bundled with the Electron app, talking to an embedded Postgres,
    #: single workspace, loopback only.
    LOCAL = "local"
    #: Multi-tenant: hosted by us, or on-prem for a cowork install.
    SERVER = "server"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="ACCOUNTING_",
        env_file=".env",
        extra="ignore",
    )

    deployment_mode: DeploymentMode = DeploymentMode.LOCAL

    #: Read/write connection used by every normal request. Must authenticate as
    #: `accounting_app` from db/roles.sql, NOT as the role that owns the tables
    #: or ran the migrations: a table's owner is exempt from its own row-level
    #: security policies, so connecting as the owner leaves migration 0004's
    #: tenant isolation in place and inert. Checked at startup, and fatal in
    #: server mode.
    database_url: str = "postgresql://accounting_app:accounting@localhost:5432/accounting"

    #: Separate connection for generated text-to-SQL, authenticating as the
    #: `nl_query` role from db/roles.sql: read-only, statement-timed-out, and
    #: able to see only the `ledger_query` schema. Deliberately a distinct URL
    #: rather than a flag on the main pool -- the isolation is the role, and a
    #: role cannot be switched on per query.
    nl_query_database_url: str | None = None

    #: Creating a workspace is the one write `accounting_app` structurally
    #: cannot make: row-level security compares `workspace_id` against
    #: `app_current_workspace()`, and there is no workspace to scope the
    #: session to yet (db/README.md, "Creating a workspace cannot happen
    #: through the app connection"). This authenticates as the table owner
    #: instead -- exempt from RLS by ownership, per db/roles.sql -- so it is
    #: deliberately unset by default rather than defaulted to anything, unlike
    #: `database_url` above: a shipped default for an RLS-bypassing role is a
    #: standing risk that a shipped default for the RLS-bound one is not.
    provisioning_database_url: str | None = None

    #: Identity operations (register, login, session resolution) authenticate
    #: as `accounting_auth` from db/roles.sql: narrow grants on
    #: users/user_credentials/sessions/workspace_members, no reach into
    #: ledger data. Unlike `provisioning_database_url`, this gets a working
    #: default -- `accounting_auth` is not RLS-exempt (0007), so it carries
    #: the same risk profile as `database_url`'s default, not
    #: `provisioning_database_url`'s.
    auth_database_url: str = "postgresql://accounting_auth:accounting@localhost:5432/accounting"

    #: Name of the session cookie set by POST /auth/login and /auth/register.
    session_cookie_name: str = "accounting_session"

    #: How long a session stays valid after creation. No sliding refresh yet
    #: -- a session is issued once and simply expires; re-authenticating is
    #: the only renewal path for now.
    session_ttl_days: int = 30

    #: How long a password-reset link/token stays valid.
    password_reset_ttl_minutes: int = 30

    #: SMTP is genuinely optional -- most installs of this software are a
    #: single desktop machine, where "email a reset link" doesn't make sense
    #: (BUSINESS_PRINCIPLES.md: self-hosted-first). Unset by default;
    #: `mail.send_mail` logs instead of sending when `smtp_host` is None, so
    #: the password-reset feature stays fully functional either way.
    smtp_host: str | None = None
    smtp_port: int = 587
    smtp_username: str | None = None
    smtp_password: str | None = None
    smtp_from_address: str = "accounting@localhost"
    smtp_use_tls: bool = True

    #: Where the reset link points. No dashboard consumes this path yet
    #: (only apps/desktop and apps/server exist, per ARCHITECTURE.md) --
    #: the desktop app's own reset screen takes a pasted token instead, so
    #: this link is a forward-compatible courtesy, not load-bearing today.
    app_base_url: str = "http://localhost:5173"

    db_pool_min_size: int = 1
    db_pool_max_size: int = 10

    #: In LOCAL mode the desktop shell owns the only client, so CORS stays shut.
    cors_allow_origins: list[str] = Field(default_factory=list)

    log_level: str = "INFO"

    @property
    def is_multi_tenant(self) -> bool:
        return self.deployment_mode is DeploymentMode.SERVER


@lru_cache
def get_settings() -> Settings:
    return Settings()
