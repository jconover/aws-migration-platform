"""Runtime configuration sourced from the environment."""

from functools import lru_cache

from pydantic import Field, PostgresDsn
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings.

    Secrets arrive as environment variables. In AWS they are injected from
    Secrets Manager by the Secrets Store CSI driver (EKS) or by the task
    definition's ``secrets`` block (ECS); nothing is read from disk.
    """

    model_config = SettingsConfigDict(env_prefix="APP_", env_file=None, extra="ignore")

    environment: str = "local"
    log_level: str = "INFO"
    database_url: PostgresDsn = Field(
        default=PostgresDsn(
            "postgresql+psycopg://postgres:postgres@localhost:5432/migration_tracker"
        )
    )
    db_pool_size: int = 5
    db_max_overflow: int = 10
    db_connect_timeout: int = 5
    artifact_bucket: str = ""

    @property
    def sqlalchemy_url(self) -> str:
        """Return the database URL as the string SQLAlchemy expects."""
        return str(self.database_url)


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return process-wide settings, parsed once."""
    return Settings()
