site: styles site/index.html site/api.html site/spec.html site/api-docs site/roadmap.html site/primer.html site/spec.pdf site/primer.pdf | site_dir
.PHONY: site

site_dir:
	mkdir -p site
.PHONY: site_dir

styles: site/styles/styles.css
.PHONY: styles

site/styles/styles.css: docs/styles/styles.css | site_dir
	mkdir -p site/styles/
	cp docs/styles/styles.css site/styles/styles.css


site/api.html:
	pandoc --defaults="docs/.pandoc" docs/api.md -o "site/api.html";

site/spec.html:  docs/spec/*.md docs/spec/.pandoc docs/template/header.html | site_dir
	pandoc --defaults="docs/spec/.pandoc" --mathml docs/spec/*.md -o "site/spec.html";

site/index.html:  docs/index.md docs/.pandoc docs/template/header.html | site_dir
	pandoc --defaults="docs/.pandoc" docs/index.md -o "site/index.html";

site/roadmap.html: docs/roadmap/*.md docs/.pandoc docs/template/header.html | site_dir
	pandoc --defaults="docs/.pandoc" docs/roadmap/*.md -o "site/roadmap.html";

site/primer.html: docs/primer.md docs/.pandoc docs/template/header.html | site_dir
	pandoc --defaults="docs/.pandoc" docs/primer.md -o "site/primer.html";

site/api-docs: | site_dir
	melos doc --no-select 2>&1 | tee doc.log

site/spec.epub: docs/spec/*.md | site_dir
	pandoc docs/spec/*.md -o site/spec.epub \
		--include-before-body docs/template/preface.md

site/spec.pdf: docs/spec/*.md | site_dir
	pandoc docs/spec/*.md --pdf-engine=xelatex -o site/spec.pdf \
		-V mainfont="DejaVu Sans" \
  		-V monofont="DejaVu Sans Mono" \
		-H docs/template/header.tex

site/primer.pdf: docs/primer.md | site_dir
	pandoc docs/primer.md --pdf-engine=xelatex -o site/primer.pdf \
		--defaults="docs/.pandoc_pdf" \
		-V mainfont="DejaVu Sans" \
  		-V monofont="DejaVu Sans Mono" \
		-H docs/template/header.tex
