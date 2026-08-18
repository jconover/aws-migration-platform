"""Persistence models and API schemas for tracked workloads."""

from __future__ import annotations

from datetime import UTC, datetime
from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import DateTime, Enum, Integer, String, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    """Declarative base for all ORM models."""


class MigrationStatus(StrEnum):
    """Lifecycle of a workload moving from the datacentre into AWS."""

    DISCOVERED = "discovered"
    ASSESSED = "assessed"
    IN_FLIGHT = "in_flight"
    CUTOVER = "cutover"
    VALIDATED = "validated"
    ROLLED_BACK = "rolled_back"


class Strategy(StrEnum):
    """The 7 Rs migration strategy chosen for a workload."""

    REHOST = "rehost"
    REPLATFORM = "replatform"
    REFACTOR = "refactor"
    REPURCHASE = "repurchase"
    RETIRE = "retire"
    RETAIN = "retain"
    RELOCATE = "relocate"


class Workload(Base):
    """A single application or service in the migration portfolio."""

    __tablename__ = "workloads"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(200), unique=True, nullable=False, index=True)
    wave: Mapped[int] = mapped_column(Integer, nullable=False, index=True)
    strategy: Mapped[Strategy] = mapped_column(
        Enum(Strategy, name="migration_strategy"), nullable=False
    )
    status: Mapped[MigrationStatus] = mapped_column(
        Enum(MigrationStatus, name="migration_status"),
        nullable=False,
        default=MigrationStatus.DISCOVERED,
        index=True,
    )
    owner: Mapped[str] = mapped_column(String(200), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )


class WorkloadCreate(BaseModel):
    """Payload accepted when registering a workload."""

    name: str = Field(min_length=1, max_length=200)
    wave: int = Field(ge=1, le=99)
    strategy: Strategy
    owner: str = Field(min_length=1, max_length=200)


class WorkloadRead(BaseModel):
    """Workload representation returned to clients."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    wave: int
    strategy: Strategy
    status: MigrationStatus
    owner: str
    created_at: datetime
    updated_at: datetime


class StatusUpdate(BaseModel):
    """Payload accepted when advancing a workload's status."""

    status: MigrationStatus


class WaveSummary(BaseModel):
    """Aggregate progress for a single migration wave."""

    wave: int
    total: int
    completed: int
    percent_complete: float
    generated_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
