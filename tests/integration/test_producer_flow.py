import ingestion.producer as prod


class FakeSettings:
    def __init__(self):
        self.openalex_email = "me@example.com"
        self.openalex_base_url = "https://api.openalex.org"
        self.aws_region = "us-east-1"
        self.firehose_name = "stream"
        self.batch_size = 2
        self.sleep_seconds = 0
        self.source = "openalex"

    def validate(self):
        return None


class FakeOA:
    def __init__(self, *a, **k):
        pass

    def works_stream(
        self,
        per_page=50,
        updated_since=None,
        max_pages=None,
        sleep_seconds=0,
        query_params=None,
    ):
        for i in range(3):
            yield {
                "id": f"W{i}",
                "title": "T",
                "host_venue": {"display_name": "V"},
                "authorships": [{"author": {"display_name": "A"}}],
                "publication_year": 2024,
            }


class FakeSink:
    def __init__(self, *a, **k):
        pass

    def put_records(self, recs):
        raise AssertionError("Should not be called when dry_run=True")


def test_producer_main_dry_run_executes_without_network(monkeypatch, capsys):
    monkeypatch.setattr(prod, "Settings", FakeSettings)
    monkeypatch.setattr(prod, "OpenAlexClient", FakeOA)
    monkeypatch.setattr(prod, "FirehoseSink", FakeSink)

    prod.main(per_page=2, max_pages=1, batch_size=2, batch_sleep=0, dry_run=True)
    out = capsys.readouterr().out
    assert "Producer summary" in out
