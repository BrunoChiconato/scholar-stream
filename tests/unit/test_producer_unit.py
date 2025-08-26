from datetime import datetime, timezone
from ingestion.schema import Envelope, OpenAlexWork
import ingestion.producer as prod


def test_strip_run_alias_removes_second_token():
    args = ["-m", "run", "--batch-size", "10"]
    prod._strip_run_alias(args)
    assert args == ["-m", "--batch-size", "10"]


def make_batch(n=3):
    now = datetime(2024, 1, 1, tzinfo=timezone.utc)
    base = {
        "id": "W1",
        "title": "T",
        "publication_year": 2024,
        "host_venue": {"display_name": "V"},
        "authorships": [{"author": {"display_name": "A"}}],
    }
    envs = []
    for i in range(n):
        w = OpenAlexWork.model_validate({**base, "id": f"W{i}"})
        envs.append(Envelope.from_openalex(w, now, now, "x@ex.com", "openalex"))
    return envs


class FakeSink:
    def __init__(self):
        self.last_records = None

    def put_records(self, recs):
        self.last_records = recs
        return {
            "FailedPutCount": 1,
            "RequestResponses": [{"ErrorCode": "X", "ErrorMessage": "boom"}]
            * len(recs),
        }


def test_flush_dry_run_does_not_call_sink(capsys):
    sink = FakeSink()
    total, failed = prod.flush(make_batch(2), sink, True, total=0, failed=0)
    out = capsys.readouterr().out
    assert "Dry-run" in out
    assert total == 0 and failed == 0
    assert sink.last_records is None


def test_flush_updates_counts_and_reports_failures(capsys):
    sink = FakeSink()
    total, failed = prod.flush(make_batch(3), sink, False, total=5, failed=2)
    out = capsys.readouterr().out
    assert "had failures" in out
    assert total == 8
    assert failed == 3


def test_flush_uses_alias_load_id_in_payload():
    sink = FakeSink()
    prod.flush(make_batch(1), sink, False, total=0, failed=0)
    assert sink.last_records is not None
    assert "_LOAD_ID" in sink.last_records[0], "alias key must be present"
