.PHONY: docs

docs: site/index.html site/spec.html

site/spec.html: docs/spec/*.md docs/spec/.pandoc
	pandoc --defaults="docs/spec/.pandoc" docs/spec/*.md -o "site/spec.html"; \

site/index.html: docs/index.md docs/.pandoc
	pandoc --defaults="docs/.pandoc" docs/index.md -o "site/index.html"; \
