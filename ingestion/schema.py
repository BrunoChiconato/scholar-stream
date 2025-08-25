from __future__ import annotations
from pydantic import BaseModel, Field, ConfigDict
from typing import Optional, List
from datetime import datetime
import uuid


class HostVenue(BaseModel):
    display_name: Optional[str] = None


class AuthorRef(BaseModel):
    display_name: Optional[str] = None


class Authorship(BaseModel):
    author: Optional[AuthorRef] = None


class OpenAlexWork(BaseModel):
    model_config = ConfigDict(extra="ignore")
    id: Optional[str] = None
    doi: Optional[str] = None
    title: Optional[str] = None
    publication_year: Optional[int] = None
    host_venue: Optional[HostVenue] = None
    authorships: Optional[List[Authorship]] = None
    email: Optional[str] = None
    event_ts: Optional[datetime] = None


class Envelope(BaseModel):
    """Canonical record we push to Firehose → Snowflake.RECORD (VARIANT)."""

    id: Optional[str] = None
    doi: Optional[str] = None
    title: Optional[str] = None
    publication_year: Optional[int] = None
    host_venue: Optional[str] = Field(
        default=None, description="host_venue.display_name"
    )
    primary_author: Optional[str] = None
    email: Optional[str] = None
    event_ts: datetime
    ingest_ts: datetime
    source: str = "openalex"
    load_id: str = Field(default_factory=lambda: str(uuid.uuid4()), alias="_LOAD_ID")

    @classmethod
    def from_openalex(
        cls,
        w: OpenAlexWork,
        event_ts: datetime,
        ingest_ts: datetime,
        email: Optional[str],
        source: str,
    ) -> "Envelope":
        primary = None
        if w.authorships and len(w.authorships) > 0 and w.authorships[0].author:
            primary = w.authorships[0].author.display_name
        return cls(
            id=w.id,
            doi=w.doi,
            title=w.title,
            publication_year=w.publication_year,
            host_venue=w.host_venue.display_name if w.host_venue else None,
            primary_author=primary,
            email=email,
            event_ts=event_ts,
            ingest_ts=ingest_ts,
            source=source,
        )
