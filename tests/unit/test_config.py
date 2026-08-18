"""Unit tests for settings parsing."""

from app.config import Settings, get_settings


def test_defaults_are_local_safe():
    settings = Settings()
    assert settings.environment == "local"
    assert settings.sqlalchemy_url.startswith("postgresql+psycopg://")


def test_environment_overrides_are_applied(monkeypatch):
    monkeypatch.setenv("APP_ENVIRONMENT", "prod")
    monkeypatch.setenv("APP_LOG_LEVEL", "warning")
    monkeypatch.setenv("APP_DB_POOL_SIZE", "20")
    settings = Settings()
    assert settings.environment == "prod"
    assert settings.log_level == "warning"
    assert settings.db_pool_size == 20


def test_database_url_is_parsed_from_environment(monkeypatch):
    monkeypatch.setenv("APP_DATABASE_URL", "postgresql+psycopg://u:p@db.internal:5432/tracker")
    assert Settings().sqlalchemy_url == "postgresql+psycopg://u:p@db.internal:5432/tracker"


def test_get_settings_is_cached():
    get_settings.cache_clear()
    assert get_settings() is get_settings()
    get_settings.cache_clear()
