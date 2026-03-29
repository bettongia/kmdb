.DEFAULT_GOAL := default

.PHONY: site dart_doc test default checks coverage license_check license_add styles clean spec

COVERAGE_DIR=coverage

ADDLICENSE_CONFIG=addlicense_config.txt

default: test site checks

site: site/ styles site/index.html site/spec.html site/api/index.html site/roadmap.html

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

site/api/index.html: lib/*.dart lib/**/*.dart
	dart doc -o site/api

site/spec.epub: site/ docs/spec/*.md
	pandoc docs/spec/*.md -o site/spec.epub \
		--include-before-body docs/template/preface.md

# To get PDFs building on a Mac:
# brew install --cask mactex
# sudo tlmgr update --self --all
# sudo tlmgr paper a4
# brew install --cask font-dejavu
site/spec.pdf: site/ docs/spec/*.md
	pandoc docs/spec/*.md --pdf-engine=xelatex -o site/spec.pdf \
		-V mainfont="DejaVu Sans" \
  		-V monofont="DejaVu Sans Mono" \
		-H docs/template/header.tex

site/primer.pdf: site/ docs/primer.md
	pandoc docs/primer.md --pdf-engine=xelatex -o site/primer.pdf \
		-V mainfont="DejaVu Sans" \
  		-V monofont="DejaVu Sans Mono" \
		-H docs/template/header.tex

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

clean:
	rm -rf site
	rm -rf coverage
