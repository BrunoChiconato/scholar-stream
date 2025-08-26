import pytest
import sys
import pathlib
from datetime import datetime, timezone


ROOT = pathlib.Path(__file__).resolve().parents[1]

if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


@pytest.fixture
def sample_openalex_item():
    return {
        "id": "W123",
        "doi": "10.1234/abc",
        "title": "A Study on Streams",
        "publication_year": 2024,
        "host_venue": {"display_name": "VenueX"},
        "authorships": [{"author": {"display_name": "Alice Smith"}}],
        "extra_field": "ignored",
    }


@pytest.fixture
def fixed_now():
    return datetime(2024, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
