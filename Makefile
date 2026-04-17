.DEFAULT_GOAL := default

COVERAGE_DIR=site/coverage
KMDB_PKG=packages/kmdb
KMDB_CLI_PKG=packages/kmdb_cli
KMDB_UI_PKG=packages/kmdb_ui

ADDLICENSE_CONFIG=addlicense_config.txt

default: site/ format analyze checks site
.PHONY: default

analyze:
	melos run analyze
.PHONY: analyze

pre_commit: clean default
.PHONY: pre_commit

cicd: clean test default e2e_test
.PHONY: cicd

tests_all: test e2e_test
.PHONY: tests_all

prepare:
	dart pub global activate melos
	dart pub global activate coverage
	melos bootstrap
.PHONY: prepare

test: test.log
.PHONY: test

test.log: packages/**
	melos test --no-select | tee test.log


e2e_test: e2e_test.log
.PHONY: e2e_test

e2e_test.log: packages/**
	melos e2e-test | tee e2e_test.log

checks: coverage.log license_check
.PHONY: checks

license_check:
	melos licenses

license_add:
	melos licenses:add

.PHONY: license_add license_check

site: styles site/index.html site/spec.html site/api/index.html site/roadmap.html site/primer.html site/spec.pdf site/primer.pdf | site/
.PHONY: site

site/:
	mkdir -p site

styles: site/styles/styles.css
.PHONY: styles

site/styles/styles.css: docs/styles/styles.css | site/
	mkdir -p site/styles/
	cp docs/styles/styles.css site/styles/styles.css


site/spec.html:  docs/spec/*.md docs/spec/.pandoc docs/template/header.html | site/
	pandoc --defaults="docs/spec/.pandoc" --mathml docs/spec/*.md -o "site/spec.html";

site/index.html:  docs/index.md docs/.pandoc docs/template/header.html | site/
	pandoc --defaults="docs/.pandoc" docs/index.md -o "site/index.html";

site/roadmap.html: docs/roadmap.md docs/.pandoc docs/template/header.html | site/
	pandoc --defaults="docs/.pandoc" docs/roadmap.md -o "site/roadmap.html";

site/primer.html: docs/primer.md docs/.pandoc docs/template/header.html | site/
	pandoc --defaults="docs/.pandoc" docs/primer.md -o "site/primer.html";

site/api/index.html: $(KMDB_PKG)/**/*.dart | site/
	dart doc $(KMDB_PKG) -o site/api

site/spec.epub: docs/spec/*.md | site/
	pandoc docs/spec/*.md -o site/spec.epub \
		--include-before-body docs/template/preface.md

coverage: coverage.log
.PHONY: coverage

coverage.log: packages/** | site/
	melos coverage | tee coverage.log

site/spec.pdf: docs/spec/*.md | site/
	pandoc docs/spec/*.md --pdf-engine=xelatex -o site/spec.pdf \
		-V mainfont="DejaVu Sans" \
  		-V monofont="DejaVu Sans Mono" \
		-H docs/template/header.tex

site/primer.pdf: docs/primer.md | site/
	pandoc docs/primer.md --pdf-engine=xelatex -o site/primer.pdf \
		--defaults="docs/.pandoc_pdf" \
		-V mainfont="DejaVu Sans" \
  		-V monofont="DejaVu Sans Mono" \
		-H docs/template/header.tex

format:
	melos format
.PHONY: format

clean:
	melos clean
	rm -rf site
	rm -f *.log
	melos bootstrap
.PHONY: clean
