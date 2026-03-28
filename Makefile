.PHONY: docs dart_doc

docs: site/index.html site/spec.html dart_doc

site/spec.html: docs/spec/*.md docs/spec/.pandoc
	pandoc --defaults="docs/spec/.pandoc" docs/spec/*.md -o "site/spec.html"; \

site/index.html: docs/index.md docs/.pandoc
	pandoc --defaults="docs/.pandoc" docs/index.md -o "site/index.html"; \

dart_doc:
	dart doc -o site/api
