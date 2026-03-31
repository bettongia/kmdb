.DEFAULT_GOAL := default

.PHONY: test site dart_doc default checks coverage license_check license_add styles clean


COVERAGE_DIR=site/coverage
KMDB_PKG=packages/kmdb
KMDB_CLI_PKG=packages/kmdb_cli

ADDLICENSE_CONFIG=addlicense_config.txt

default: site/ checks site

test: test.log

test.log: $(KMDB_PKG)/**/*.dart $(KMDB_CLI_PKG)/**/*.dart
	melos test --no-select | tee test.log

checks: coverage license_check

license_check:
	melos licenses

license_add:
	melos licenses:add

coverage: site/coverage/html/index.html

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

site/coverage/html/index.html: $(KMDB_PKG)/**/*.dart $(KMDB_CLI_PKG)/**/*.dart
	melos coverage

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
