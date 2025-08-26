import pytest
from ingestion.config import Settings


def test_settings_validate_requires_core_env():
    s = Settings(openalex_email="", aws_region="us-east-1", firehose_name="x")
    with pytest.raises(ValueError):
        s.validate()


def test_settings_validate_ok():
    s = Settings(
        openalex_email="me@example.com", aws_region="us-east-1", firehose_name="stream"
    )
    s.validate()
