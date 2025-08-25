#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage:
  $0 --user FIREHOSE_LOADER --secret-name scholarstream/snowflake/firehose \\
     [--key-dir .keys] [--region us-east-1]

Behavior:
  - Generates an unencrypted PKCS#8 private key (.keys/rsa_key.p8) and public key (.keys/rsa_key.pub)
  - Creates sql/06_link_public_key.sql (from template if present, or inline)
  - Runs: python sql/apply.py --files 00_service_user.sql 06_link_public_key.sql
  - Writes/rotates AWS Secrets Manager secret with { "user", "private_key" } only
EOF
}

USER_NAME="FIREHOSE_LOADER"
SECRET_NAME="scholarstream/snowflake/firehose"
KEY_DIR=".keys"
REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --secret-name) SECRET_NAME="$2"; shift 2 ;;
    --key-dir) KEY_DIR="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

mkdir -p "${KEY_DIR}"
PRI_PEM="${KEY_DIR}/rsa_key.p8"
PUB_PEM="${KEY_DIR}/rsa_key.pub"

if [[ ! -f "${PRI_PEM}" ]]; then
  echo ">> Generating PKCS#8 private key at ${PRI_PEM} (unencrypted)"
  openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out "${PRI_PEM}"
else
  echo ">> Reusing private key: ${PRI_PEM}"
fi

if [[ ! -f "${PUB_PEM}" ]]; then
  echo ">> Deriving public key at ${PUB_PEM}"
  openssl rsa -in "${PRI_PEM}" -pubout -out "${PUB_PEM}"
else
  echo ">> Reusing public key: ${PUB_PEM}"
fi

PUB_B64=$(awk '/BEGIN PUBLIC KEY/{f=1;next}/END PUBLIC KEY/{f=0} f {gsub(/\r/,""); gsub(/[[:space:]]+/,""); printf "%s",$0}' "${PUB_PEM}")
[[ -z "${PUB_B64}" ]] && { echo "!! Failed to extract public key body"; exit 2; }

TEMPLATE="sql/06_link_public_key.sql.tmpl"
TARGET="sql/06_link_public_key.sql"
if [[ -f "${TEMPLATE}" ]]; then
  sed "s|{{RSA_PUBLIC_KEY}}|${PUB_B64}|g" "${TEMPLATE}" > "${TARGET}"
else
  cat > "${TARGET}" <<SQL
USE ROLE SECURITYADMIN;
-- Link the RSA public key to the service user
ALTER USER ${USER_NAME}
  SET RSA_PUBLIC_KEY='${PUB_B64}';
SQL
fi

echo ">> Applying SQL to create user and link public key..."
python sql/apply.py --files 00_service_user.sql 06_link_public_key.sql

FLATTENED_KEY="$(
  awk 'BEGIN{inblk=0}
       /-----BEGIN PRIVATE KEY-----/{inblk=1;next}
       /-----END PRIVATE KEY-----/{inblk=0;next}
       inblk {
         gsub(/\r/,"");           # drop CR
         gsub(/[[:space:]]+/,""); # drop any whitespace (incl. tabs/newlines/spaces)
         printf "%s",$0           # concatenate into a single line
       }' "${PRI_PEM}"
)"

if [[ -z "${FLATTENED_KEY}" ]]; then
  echo "!! Failed to flatten private key from ${PRI_PEM}"
  exit 3
fi

SECRET_JSON=$(jq -cn --arg user "${USER_NAME}" --arg pk "${FLATTENED_KEY}" \
  '{user:$user, private_key:$pk}')

echo ">> Writing/rotating secret in AWS Secrets Manager"
AWS_ARGS=()
[[ -n "${REGION}" ]] && AWS_ARGS+=(--region "${REGION}")

if aws "${AWS_ARGS[@]}" secretsmanager describe-secret --secret-id "${SECRET_NAME}" >/dev/null 2>&1; then
  aws "${AWS_ARGS[@]}" secretsmanager update-secret \
    --secret-id "${SECRET_NAME}" \
    --secret-string "${SECRET_JSON}" >/dev/null
  echo ">> Secret updated: ${SECRET_NAME}"
else
  aws "${AWS_ARGS[@]}" secretsmanager create-secret \
    --name "${SECRET_NAME}" \
    --secret-string "${SECRET_JSON}" >/dev/null
  echo ">> Secret created: ${SECRET_NAME}"
fi

READ_BACK="$(aws "${AWS_ARGS[@]}" secretsmanager get-secret-value --secret-id "${SECRET_NAME}" --query 'SecretString' --output text)"
echo "$READ_BACK" | jq -e '.user and .private_key and (.private_key|test("\\n")|not)' >/dev/null || {
  echo "!! Secret content validation failed (missing keys or still contains newlines)"; exit 4;
}

echo ">> Done."
