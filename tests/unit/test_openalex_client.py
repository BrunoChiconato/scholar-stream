import types
from ingestion.openalex_client import OpenAlexClient, headers_template
import ingestion.openalex_client as oac


def test_headers_template_user_agent():
    h = headers_template("me@example.com")
    assert "User-Agent" in h
    assert "mailto:me@example.com" in h["User-Agent"]


class FakeResponse:
    def __init__(self, status, json_payload=None, headers=None):
        self.status_code = status
        self._json = json_payload or {}
        self.headers = headers or {}

    def json(self):
        return self._json

    def raise_for_status(self):
        if self.status_code >= 400 and self.status_code != 429:
            raise RuntimeError(f"HTTP {self.status_code}")


class FakeSession:
    def __init__(self, responses):
        self._responses = list(responses)
        self.headers = {}

    def get(self, url, params=None, timeout=None):
        if not self._responses:
            raise AssertionError("No more fake responses")
        return self._responses.pop(0)


def test_works_stream_handles_429_and_pagination(monkeypatch):
    responses = [
        FakeResponse(429, headers={"Retry-After": "0"}),
        FakeResponse(
            200,
            json_payload={
                "results": [{"id": 1}, {"id": 2}],
                "meta": {"next_cursor": "abc"},
            },
        ),
        FakeResponse(
            200, json_payload={"results": [{"id": 3}], "meta": {"next_cursor": None}}
        ),
    ]
    monkeypatch.setattr(
        oac, "requests", types.SimpleNamespace(Session=lambda: FakeSession(responses))
    )
    monkeypatch.setattr(oac, "sleep", lambda s: None)

    cli = OpenAlexClient("https://api.openalex.org", "me@example.com")
    got = list(cli.works_stream(per_page=2, sleep_seconds=0))
    assert [g["id"] for g in got] == [1, 2, 3]
