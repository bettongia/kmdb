.DEFAULT_GOAL := default

.PHONY: docs dart_doc test default checks coverage license_check license_add

COVERAGE_DIR=coverage

ADDLICENSE_CONFIG=addlicense_config.txt

default: test checks docs

docs: site/index.html site/spec.html dart_doc

site/spec.html: docs/spec/*.md docs/spec/.pandoc
	pandoc --defaults="docs/spec/.pandoc" docs/spec/*.md -o "site/spec.html"; \

site/index.html: docs/index.md docs/.pandoc
	pandoc --defaults="docs/.pandoc" docs/index.md -o "site/index.html"; \

dart_doc:
	dart doc -o site/api

checks: coverage license_check

test:
	dart test

coverage:
	dart pub global run coverage:test_with_coverage --out $(COVERAGE_DIR)
	lcov --summary $(COVERAGE_DIR)/lcov.info
	genhtml $(COVERAGE_DIR)/lcov.info -o $(COVERAGE_DIR)/html

license_check:
	@echo "Checking for license headers..."
	cat $(ADDLICENSE_CONFIG) | xargs addlicense --check

license_add:
	cat $(ADDLICENSE_CONFIG) | xargs addlicense
