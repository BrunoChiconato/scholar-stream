from __future__ import annotations
import requests
from typing import Dict, Iterator, Any, Optional
from time import sleep

DEFAULT_TIMEOUT = 30


def headers_template(mail: str) -> Dict[str, str]:
    return {"User-Agent": f"ScholarStream/0.1 (+mailto:{mail})"}


class OpenAlexClient:
    def __init__(self, base_url: str, mailto: str):
        if not mailto:
            raise ValueError(
                "OpenAlex requires a contact email (mailto). Set OPENALEX_EMAIL."
            )
        self.base_url = base_url.rstrip("/")
        self.mailto = mailto

    def works_stream(
        self,
        per_page: int = 50,
        updated_since: Optional[str] = None,
        max_pages: Optional[int] = None,
        sleep_seconds: float = 1.0,
        query_params: Optional[Dict[str, Any]] = None,
    ) -> Iterator[Dict[str, Any]]:
        """
        Iterates through /works with cursor pagination.
        """
        params: Dict[str, Any] = {
            "per_page": per_page,
            "mailto": self.mailto,
            "cursor": "*",
        }
        if updated_since:
            params["from_updated_date"] = updated_since
        if query_params:
            params.update(query_params)

        page_count = 0
        url = f"{self.base_url}/works"
        session = requests.Session()
        session.headers.update(headers_template(self.mailto))

        while True:
            resp = session.get(url, params=params, timeout=DEFAULT_TIMEOUT)
            if resp.status_code == 429:
                retry_after = int(resp.headers.get("Retry-After", "2"))
                sleep(retry_after)
                continue
            resp.raise_for_status()
            payload = resp.json()
            results = payload.get("results", [])
            for item in results:
                yield item

            meta = payload.get("meta", {})
            next_cursor = meta.get("next_cursor")
            if not next_cursor:
                break
            params["cursor"] = next_cursor

            page_count += 1
            if max_pages and page_count >= max_pages:
                break
            if sleep_seconds:
                sleep(sleep_seconds)
