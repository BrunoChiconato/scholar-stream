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
	     /^[A-Za-z0-9_./-]+:.*##/ { printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\n\033[1mRequired .env keys\033[0m\n"
	@printf "  AWS:       AWS_REGION, SECRET_NAME\n"
	@printf "  Firehose:  FIREHOSE_NAME (optional default ok)\n"
	@printf "  Snowflake (dest): SNOWFLAKE_ACCOUNT_URL, FIREHOSE_SNOWFLAKE_USER\n"
	@printf "  Snowflake (apply): SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD, SNOWFLAKE_DATABASE\n\n"
	@printf "\033[1mTypical flow\033[0m\n"
	@printf "  1) make env-show                  # inspect loaded env\n"
	@printf "  2) make bootstrap-identity-secure # create/link RSA key & write secret (once)\n"
	@printf "  3) make tf-init                   # terraform init\n"
	@printf "  4) make tf-plan                   # plan\n"
	@printf "  5) make tf-apply                  # apply\n"
	@printf "  6) make send-test                 # push one test record through Firehose\n\n"

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
