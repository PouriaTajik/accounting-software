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
