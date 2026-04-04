.DEFAULT_GOAL := default

.PHONY: test cli_test site dart_doc default checks coverage license_check license_add styles clean


COVERAGE_DIR=site/coverage
KMDB_PKG=packages/kmdb
KMDB_CLI_PKG=packages/kmdb_cli

ADDLICENSE_CONFIG=addlicense_config.txt

default: site/ checks site

prepare:
	dart pub global activate melos
	dart pub global activate coverage
	melos bootstrap

test: test.log cli_test

test.log: $(KMDB_PKG)/**/*.dart
	melos test --scope=kmdb | tee cli_test.log

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

site: site/ styles site/index.html site/spec.html site/api/index.html site/roadmap.html site/primer.html site/spec.pdf site/primer.pdf

site/:
	mkdir -p site

styles: site/styles/styles.css

site/styles/styles.css: docs/styles/styles.css
	mkdir -p site/styles/
	cp docs/styles/styles.css site/styles/styles.css


site/spec.html: site/ docs/spec/*.md docs/spec/.pandoc docs/template/header.html
	pandoc --defaults="docs/spec/.pandoc" docs/spec/*.md -o "site/spec.html";

site/index.html: site/ docs/index.md docs/.pandoc docs/template/header.html
	pandoc --defaults="docs/.pandoc" docs/index.md -o "site/index.html";

site/roadmap.html: site/ docs/roadmap.md docs/.pandoc docs/template/header.html
	pandoc --defaults="docs/.pandoc" docs/roadmap.md -o "site/roadmap.html";

site/primer.html: site/ docs/primer.md docs/.pandoc docs/template/header.html
	pandoc --defaults="docs/.pandoc" docs/primer.md -o "site/primer.html";

site/api/index.html: $(KMDB_PKG)/**/*.dart
	dart doc $(KMDB_PKG) -o site/api

site/spec.epub: site/ docs/spec/*.md
	pandoc docs/spec/*.md -o site/spec.epub \
		--include-before-body docs/template/preface.md

coverage.log: $(KMDB_PKG)/**/*.dart $(KMDB_CLI_PKG)/**/*.dart
	melos coverage | tee coverage.log

site/spec.pdf: site/ docs/spec/*.md
	pandoc docs/spec/*.md --pdf-engine=xelatex -o site/spec.pdf \
		-V mainfont="DejaVu Sans" \
  		-V monofont="DejaVu Sans Mono" \
		-H docs/template/header.tex

site/primer.pdf: site/ docs/primer.md
	pandoc docs/primer.md --pdf-engine=xelatex -o site/primer.pdf \
		--defaults="docs/.pandoc_pdf" \
		-V mainfont="DejaVu Sans" \
  		-V monofont="DejaVu Sans Mono" \
		-H docs/template/header.tex

$(KMDB_PKG)/**/*.dart:

$(KMDB_CLI_PKG)/**/*.dart:

clean:
	rm -rf site
	rm e2e_test.log
	rm test.log
	rm cli_test.log
