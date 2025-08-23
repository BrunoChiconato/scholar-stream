#!/usr/bin/bash
PYTHON ?= python3
SQL_DIR := sql

.PHONY: lint clean sql-apply

help:
	@echo "Commands:"
	@echo "- make clean         -> remove caches"
	@echo "- make lint          -> ruff format and check"
	@echo "- make sql-apply     -> apply sql queries on Snowflake"
	
lint:
	ruff format . && ruff check .

clean:
	rm -rf .ruff_cache .pytest_cache
	find . -type d -name "__pycache__" -exec rm -rf {} +
	find . -name "*.pyc" -delete
	find . -name "*.pyo" -delete

## Apply Snowflake SQL scripts in order (e.g. pass extra args via ARGS="--verbose")
sql-apply:
	$(PYTHON) $(SQL_DIR)/apply.py $(ARGS)
