.DEFAULT_GOAL := default

.PHONY: default cicd pre_commit test e2e_test tests_all cli_test site dart_doc default checks coverage license_check license_add styles clean format


COVERAGE_DIR=site/coverage
KMDB_PKG=packages/kmdb
KMDB_CLI_PKG=packages/kmdb_cli
KMDB_UI_PKG=packages/kmdb_ui

ADDLICENSE_CONFIG=addlicense_config.txt

default: site/ format checks site

pre_commit: clean default

cicd: test e2e_test default

tests_all: test e2e_test

prepare:
	dart pub global activate melos
	dart pub global activate coverage
	melos bootstrap

test: test.log cli_test.log ui_test.log


ui_test: ui_test.log
.PHONY: ui_test

ui_test.log: $(KMDB_UI_PKG)/**/*.dart
	melos flutter-test --scope=kmdb_ui | tee ui_test.log

test.log: $(KMDB_PKG)/**/*.dart
	melos test --scope=kmdb | tee test.log

cli_test: cli_test.log

cli_test.log: $(KMDB_CLI_PKG)/**/*.dart $(KMDB_PKG)/**/*.dart
	melos test --scope=kmdb_cli | tee cli_test.log

e2e_test: e2e_test.log

e2e_test.log: $(KMDB_CLI_PKG)/**/*.dart $(KMDB_PKG)/**/*.dart
	melos e2e-test | tee e2e_test.log

checks: coverage.log license_check

license_check:
	melos licenses

license_add:
	melos licenses:add

site: styles site/index.html site/spec.html site/api/index.html site/roadmap.html site/primer.html site/spec.pdf site/primer.pdf | site/

site/:
	mkdir -p site

styles: site/styles/styles.css

site/styles/styles.css: docs/styles/styles.css | site/
	mkdir -p site/styles/
	cp docs/styles/styles.css site/styles/styles.css


site/spec.html:  docs/spec/*.md docs/spec/.pandoc docs/template/header.html | site/
	pandoc --defaults="docs/spec/.pandoc" docs/spec/*.md -o "site/spec.html";

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

coverage.log: $(KMDB_PKG)/**/*.dart $(KMDB_CLI_PKG)/**/*.dart | site/
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

$(KMDB_PKG)/**/*.dart:

$(KMDB_CLI_PKG)/**/*.dart:

format: $(KMDB_PKG)/**/*.dart $(KMDB_CLI_PKG)/**/*.dart
	melos format

clean:
	melos clean
	rm -rf site
	rm -f e2e_test.log
	rm -f test.log
	rm -f ui_test.log
	rm -f cli_test.log
	rm -f coverage.log
	melos bootstrap
