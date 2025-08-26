from ingestion.utils import synthetic_email


def test_synthetic_email_is_deterministic():
    a = synthetic_email("Alice Smith")
    b = synthetic_email("Alice Smith")
    assert a == b
    assert a.endswith("@example.com")


def test_synthetic_email_domain_override():
    e = synthetic_email("Bob", domain="acme.test")
    assert e.endswith("@acme.test")
    assert e.startswith("user_")
