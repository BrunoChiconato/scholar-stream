# Firehose to Snowflake (Public Internet)

This stack provisions an **Amazon Kinesis Data Firehose** delivery stream that writes into **Snowflake** over the public endpoint, using **AWS Secrets Manager** for key-pair authentication (RSA PKCS#8). It also creates **CloudWatch Logs** for debugging and an **S3 backup** path for failed records.

**Important:** Use your Snowflake **public** account URL in the form `<account_locator>.<region>.snowflakecomputing.com`.

## What gets created

- **Kinesis Firehose (destination = snowflake)** using `VARIANT_CONTENT_AND_METADATA_MAPPING`.
- **CloudWatch Logs** group/stream for Firehose diagnostics.
- **S3 bucket/prefix** for failed record backups.
- **IAM role/policies** for Firehose and Secrets Manager access.

> Credentials are **not** created by Terraform. A Secrets Manager secret is created by the `make bootstrap-identity-secure` helper and **referenced** by Terraform during `plan/apply`.

## Prerequisites

- Snowflake user with **key-pair auth** (RSA PKCS#8 **private key**), `INSERT` on target table, and default or explicit role suitable for writes.
- AWS credentials configured for the target account.
- Tools: Terraform ≥ 1.6, AWS provider 5.52+, `aws cli v2`, `jq`, `make`.

## Quickstart

1. **Inspect env**

    ```bash
    make env-show
    ```

2. **Create/link the Snowflake key and write the secret once**

    This generates an RSA key pair locally (PEM), converts the **private key to PKCS#8 (base64, no headers, no passphrase)**, and writes a JSON secret:

    ```json
    { "user": "FIREHOSE_LOADER", "private_key": "<pkcs8-base64-no-headers>" }
    ```

    ```bash
    make bootstrap-identity-secure
    ```

3. **Terraform init/plan/apply**

    `tf-plan` and `tf-apply` will auto-discover the secret ARN from `SECRET_NAME` and pass it to Terraform.

    ```bash
    make tf-init
    make tf-plan
    make tf-apply
    ```

4. **Send a test record**

    ```bash
    make send-test
    ```

You should see a successful response and a row arriving in your Snowflake target table.

## How it works (mapping)

* **Data loading option:** `VARIANT_CONTENT_AND_METADATA_MAPPING`
  Firehose writes two columns:

  * `RECORD` (VARIANT) – the JSON payload
  * `RECORD_METADATA` (OBJECT/VARIANT) – delivery metadata

> Ensure your target table has these columns compatible with Snowpipe Streaming (no `IDENTITY`, `AUTOINCREMENT`, `GEO` types, default expressions or collations on these columns). A minimal table looks like:

```sql
CREATE TABLE RAW.OPENALEX_EVENTS (
    RECORD VARIANT,
    RECORD_METADATA VARIANT
);
```

## Troubleshooting

* **`Snowflake.SecretsManagerParseError`**
  Your secret must be valid JSON with exactly:

  ```json
  { "user": "<USER>", "private_key": "<pkcs8-base64-no-headers>" }
  ```

  Re-run `make bootstrap-identity-secure` if needed.

* **`Snowflake.SSLUnverified`**
  Use the **public** account URL without `.aws`:
  `hac34976.us-east-1.snowflakecomputing.com`.

* **`Snowflake.InvalidColumns`**
  Remove unsupported column features (IDENTITY/AUTOINCREMENT/GEO/defaults/collations) and keep `RECORD` + `RECORD_METADATA` as simple VARIANT columns.

* **Permission denied / role issues**
  Grant `INSERT` on the table to the user/role used by Firehose.

## Inputs wired via Terraform

* `snowflake_account_url`, `snowflake_user`, `snowflake_database`, `snowflake_schema`, `snowflake_table`
* `content_column_name` (default: `RECORD`), `metadata_column_name` (default: `RECORD_METADATA`)
* `snowflake_retry_seconds` (retry window for temporary unavailability)
* `secret_arn` (from `SECRET_NAME`), `create_secret=false` (we use existing secret)

These are passed by the `tf-plan`/`tf-apply` targets and map to the Firehose `snowflake_configuration`.

## Clean up

```bash
make tf-destroy
```

This will destroy the Firehose stack (it will not delete the Secrets Manager secret you created manually).