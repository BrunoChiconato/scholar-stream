SHELL := /usr/bin/env bash

ifneq (,$(wildcard .env))
include .env
export $(shell sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' .env)
endif

PYTHON ?= python3
SQL_DIR := sql
INFRA_DIR:= infra

TF_WORKSPACE ?= dev
ARGS ?=
SQL_CORE_FILES := $(notdir $(wildcard $(SQL_DIR)/0[1-5]_*.sql))

.PHONY: help env-show env-check sql-check \
        lint clean sql-apply \
        bootstrap-identity-secure secret-arn \
        tf-init tf-workspace tf-validate tf-plan tf-apply tf-destroy tf-fmt \
        send-test

help:
	@printf "\n\033[1mScholarStream Make Targets\033[0m\n\n"
	@awk 'BEGIN { FS=":.*## " } \
	     /^[A-Za-z0-9_./-]+:.*##/ { printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

	@printf "\n\033[1m.env keys (grouped)\033[0m\n"
	@printf "  \033[1m[AWS / Infra]\033[0m\n"
	@printf "    AWS_REGION                (Required)                         # AWS region used by CLI/Terraform\n"
	@printf "    SECRET_NAME               (Required)                         # Secrets Manager name that stores the Snowflake keypair\n"
	@printf "    FIREHOSE_NAME             (Default: scholarstream-openalex)  # Firehose delivery stream\n"
	@printf "    SNOWFLAKE_ACCOUNT_URL     (Required)                         # Public Snowflake URL (e.g., <acct>.<region>.snowflakecomputing.com)\n"
	@printf "    FIREHOSE_SNOWFLAKE_USER   (Required)                         # Snowflake service user used by Firehose\n"
	@printf "    KEY_DIR                   (Default: .keys)                   # Where RSA keys are generated (bootstrap)\n"

	@printf "  \033[1m[Snowflake — SQL/App]\033[0m\n"
	@printf "    SNOWFLAKE_ACCOUNT         (Required for sql-apply)\n"
	@printf "    SNOWFLAKE_USER            (Required for sql-apply)\n"
	@printf "    SNOWFLAKE_PASSWORD        (Required for sql-apply)\n"
	@printf "    SNOWFLAKE_ROLE            (Default: R_ANALYST)        # Optional session role\n"
	@printf "    SNOWFLAKE_WAREHOUSE       (Default: WH_INGESTION_XS)  # Session warehouse\n"
	@printf "    SNOWFLAKE_DATABASE        (Default: SCHOLARSTREAM)\n"
	@printf "    SNOWFLAKE_SCHEMA          (Default: CURATED)          # App reads from CURATED\n"
	@printf "    SNOWFLAKE_SCHEMA_RAW      (Default: RAW)              # RAW schema for ingestion\n"
	@printf "    SNOWFLAKE_TABLE           (Default: OPENALEX_EVENTS)\n"

	@printf "  \033[1m[OpenAlex / Producer]\033[0m\n"
	@printf "    OPENALEX_EMAIL            (Required)                  # Contact email for API politeness\n"
	@printf "    OPENALEX_BASE_URL         (Default: https://api.openalex.org)\n"
	@printf "    PRODUCER_BATCH_SIZE       (Default: 50)\n"
	@printf "    PRODUCER_SLEEP_SECONDS    (Default: 2)\n"
	@printf "    SOURCE_TAG                (Default: openalex)\n"

	@printf "\n\033[1mTypical flow\033[0m\n"
	@printf "  1) make env-check                  # tools present + core env required for infra\n"
	@printf "  2) make sql-check                  # validate Snowflake credentials for SQL apply\n"
	@printf "  3) make sql-apply                  # create DB/roles/tables/views/masking\n"
	@printf "  4) make bootstrap-identity-secure  # generate RSA key, convert to PKCS#8, store secret JSON\n"
	@printf "  5) make tf-init                    # terraform init\n"
	@printf "  6) make tf-plan                    # generate infra plan (Firehose -> Snowflake)\n"
	@printf "  7) make tf-apply                   # apply infrastructure\n"
	@printf "  8) make send-test                  # send 1 NDJSON record via Firehose\n"
	@printf "  9) make run-producer               # start OpenAlex producer -> Firehose\n\n"

env-show: ## Show key .env values (sanity check)
	@echo "AWS_REGION=$(AWS_REGION)"
	@echo "SECRET_NAME=$(SECRET_NAME)"
	@echo "FIREHOSE_NAME=$(FIREHOSE_NAME)"
	@echo "SNOWFLAKE_ACCOUNT_URL=$(SNOWFLAKE_ACCOUNT_URL)"
	@echo "FIREHOSE_SNOWFLAKE_USER=$(FIREHOSE_SNOWFLAKE_USER)"
	@echo "SNOWFLAKE_ACCOUNT=$(SNOWFLAKE_ACCOUNT)"
	@echo "SNOWFLAKE_USER=$(SNOWFLAKE_USER)"
	@echo "SNOWFLAKE_PASSWORD=$$(test -n "$$SNOWFLAKE_PASSWORD" && echo '***set***' || echo '***missing***')"
	@echo "SNOWFLAKE_DATABASE=$(SNOWFLAKE_DATABASE)"
	@echo "SNOWFLAKE_SCHEMA_RAW=$(SNOWFLAKE_SCHEMA_RAW)"
	@echo "SNOWFLAKE_TABLE=$(SNOWFLAKE_TABLE)"

env-check: ## Check required tools and core env keys (.env)
	@command -v aws >/dev/null 2>&1 || { echo "aws CLI not found"; exit 1; }
	@command -v jq  >/dev/null 2>&1 || { echo "jq not found"; exit 1; }
	@command -v terraform >/dev/null 2>&1 || { echo "terraform not found"; exit 1; }
	@test -n "$(AWS_REGION)" || { echo "ERROR: AWS_REGION missing in .env"; exit 2; }
	@test -n "$(SECRET_NAME)" || { echo "ERROR: SECRET_NAME missing in .env"; exit 2; }
	@test -n "$(SNOWFLAKE_ACCOUNT_URL)" || { echo "ERROR: SNOWFLAKE_ACCOUNT_URL missing in .env"; exit 2; }
	@test -n "$(FIREHOSE_SNOWFLAKE_USER)" || { echo "ERROR: FIREHOSE_SNOWFLAKE_USER missing in .env"; exit 2; }

sql-check: ## Check Snowflake env for SQL apply (.env)
	@test -n "$(SNOWFLAKE_ACCOUNT)" || { echo "ERROR: SNOWFLAKE_ACCOUNT missing in .env"; exit 2; }
	@test -n "$(SNOWFLAKE_USER)"    || { echo "ERROR: SNOWFLAKE_USER missing in .env"; exit 2; }
	@test -n "$(SNOWFLAKE_PASSWORD)"|| { echo "ERROR: SNOWFLAKE_PASSWORD missing in .env"; exit 2; }

sql-apply: sql-check ## Apply SQL 01..05 (use FILE/FILES/ARGS to filter)
	@echo ">> Applying SQL scripts..."
	@if [ -n "$(FILE)" ] || [ -n "$(FILES)" ]; then \
	  $(PYTHON) $(SQL_DIR)/apply.py --files $${FILES:-$(FILE)} $(ARGS) ; \
	else \
	  $(PYTHON) $(SQL_DIR)/apply.py --files $(SQL_CORE_FILES) $(ARGS) ; \
	fi

lint: ## Lint Python code with Ruff
	ruff format . && ruff check .

clean: ## Cleanup caches and __pycache__
	rm -rf .ruff_cache .pytest_cache
	find . -type d -name "__pycache__" -exec rm -rf {} +
	find . -name "*.pyc" -delete
	find . -name "*.pyo" -delete

bootstrap-identity-secure: env-check ## Create/ensure service user, link RSA key, and write/rotate secret via AWS CLI
	bash $(SQL_DIR)/bootstrap_firehose_identity_secure.sh \
	  --user $(FIREHOSE_SNOWFLAKE_USER) \
	  --secret-name $(SECRET_NAME) \
	  --region $(AWS_REGION)

secret-arn: env-check ## Print the Secrets Manager ARN
	@aws secretsmanager describe-secret \
	  --secret-id $(SECRET_NAME) \
	  --query 'ARN' --output text --region $(AWS_REGION)

tf-init: env-check ## Terraform init (providers/backend)
	terraform -chdir=$(INFRA_DIR) init

tf-workspace: ## Create/select Terraform workspace (default: dev)
	@terraform -chdir=$(INFRA_DIR) workspace list >/dev/null 2>&1 || terraform -chdir=$(INFRA_DIR) init
	@if terraform -chdir=$(INFRA_DIR) workspace list | grep -q " $(TF_WORKSPACE)$$" ; then \
	  echo ">> Selecting workspace: $(TF_WORKSPACE)"; \
	  terraform -chdir=$(INFRA_DIR) workspace select $(TF_WORKSPACE) ; \
	else \
	  echo ">> Creating workspace: $(TF_WORKSPACE)"; \
	  terraform -chdir=$(INFRA_DIR) workspace new $(TF_WORKSPACE) ; \
	fi

tf-validate: ## Terraform validate (syntax/provider)
	terraform -chdir=$(INFRA_DIR) validate

tf-plan: env-check tf-workspace ## Terraform plan (auto-discovers secret ARN)
	@SECRET_ARN=$$(aws secretsmanager describe-secret \
	  --secret-id $(SECRET_NAME) \
	  --query 'ARN' --output text --region $(AWS_REGION)); \
	echo ">> Using Secret ARN: $$SECRET_ARN"; \
	terraform -chdir=$(INFRA_DIR) plan \
	  -var "create_secret=false" \
	  -var "secret_arn=$$SECRET_ARN" \
	  -var "firehose_name=$(FIREHOSE_NAME)" \
	  -var "snowflake_account_url=$(SNOWFLAKE_ACCOUNT_URL)" \
	  -var "snowflake_user=$(FIREHOSE_SNOWFLAKE_USER)" \
	  -var "snowflake_database=$(SNOWFLAKE_DATABASE)" \
	  -var "snowflake_schema=$(SNOWFLAKE_SCHEMA_RAW)" \
	  -var "snowflake_table=$(SNOWFLAKE_TABLE)"

tf-apply: env-check tf-workspace ## Terraform apply (non-interactive)
	@SECRET_ARN=$$(aws secretsmanager describe-secret \
	  --secret-id $(SECRET_NAME) \
	  --query 'ARN' --output text --region $(AWS_REGION)); \
	echo ">> Using Secret ARN: $$SECRET_ARN"; \
	terraform -chdir=$(INFRA_DIR) apply -auto-approve \
	  -var "create_secret=false" \
	  -var "secret_arn=$$SECRET_ARN" \
	  -var "firehose_name=$(FIREHOSE_NAME)" \
	  -var "snowflake_account_url=$(SNOWFLAKE_ACCOUNT_URL)" \
	  -var "snowflake_user=$(FIREHOSE_SNOWFLAKE_USER)" \
	  -var "snowflake_database=$(SNOWFLAKE_DATABASE)" \
	  -var "snowflake_schema=$(SNOWFLAKE_SCHEMA_RAW)" \
	  -var "snowflake_table=$(SNOWFLAKE_TABLE)"

tf-destroy: env-check tf-workspace ## Terraform destroy (careful!)
	@SECRET_ARN=$$(aws secretsmanager describe-secret \
	  --secret-id $(SECRET_NAME) \
	  --query 'ARN' --output text --region $(AWS_REGION)); \
	echo ">> Using Secret ARN: $$SECRET_ARN"; \
	terraform -chdir=$(INFRA_DIR) destroy -auto-approve \
	  -var "create_secret=false" \
	  -var "secret_arn=$$SECRET_ARN" \
	  -var "firehose_name=$(FIREHOSE_NAME)" \
	  -var "snowflake_account_url=$(SNOWFLAKE_ACCOUNT_URL)" \
	  -var "snowflake_user=$(FIREHOSE_SNOWFLAKE_USER)" \
	  -var "snowflake_database=$(SNOWFLAKE_DATABASE)" \
	  -var "snowflake_schema=$(SNOWFLAKE_SCHEMA_RAW)" \
	  -var "snowflake_table=$(SNOWFLAKE_TABLE)"

tf-fmt: ## Terraform fmt recursively
	terraform -chdir=$(INFRA_DIR) fmt -recursive

send-test: env-check ## Send one NDJSON record to Firehose (explicit base64)
	@test -n "$(FIREHOSE_NAME)" || { echo "ERROR: FIREHOSE_NAME missing"; exit 2; }
	@JSON=$$(jq -nc --arg now "$$(date -u +%FT%TZ)" '{hello:"world",event_ts:$$now}'); \
	  B64=$$(printf '%s' "$$JSON" | base64 | tr -d '\n'); \
	  aws firehose put-record \
	    --delivery-stream-name "$(FIREHOSE_NAME)" \
	    --record Data=$$B64 \
	    --region "$(AWS_REGION)"

run-producer: ## Run the Python producer (OpenAlex -> Firehose)
	$(PYTHON) -m ingestion.producer run --batch-size 50 --batch-sleep 1
