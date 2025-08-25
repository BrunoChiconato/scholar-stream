from dataclasses import dataclass
import os
from dotenv import load_dotenv

load_dotenv(override=True)


@dataclass
class Settings:
    aws_region: str = os.getenv("AWS_REGION", "us-east-1")
    firehose_name: str = os.getenv("FIREHOSE_NAME", "scholarstream-openalex")

    openalex_base_url: str = os.getenv("OPENALEX_BASE_URL", "https://api.openalex.org")
    openalex_email: str = os.getenv("OPENALEX_EMAIL", "")

    batch_size: int = int(os.getenv("PRODUCER_BATCH_SIZE", "50"))
    sleep_seconds: float = float(os.getenv("PRODUCER_SLEEP_SECONDS", "2"))

    source: str = os.getenv("SOURCE_TAG", "openalex")

    def validate(self) -> None:
        if not self.openalex_email:
            raise ValueError(
                "OPENALEX_EMAIL is required for polite use of the OpenAlex API."
            )
        if not self.aws_region:
            raise ValueError("AWS_REGION is required.")
        if not self.firehose_name:
            raise ValueError("FIREHOSE_NAME is required.")
