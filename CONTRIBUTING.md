# Contributing to KMDB

## Welcome

In terms of a code of conduct, it's pretty straight-forward: **Be kind or be
gone**.

This is a pretty small project so you should not expect anyone to jump to
attention and resolve your issue. Rather, it's open source so please fork it and
carry on.

## The Codebase

- The [`Makefile`](Makefile) encapsulates the main tasks such as building the
  project, running tests, building the docs etc.
- [docs](docs) contains the specifications and guides for this project. It's
  written in [Pandoc Markdown](https://pandoc.org/MANUAL.html).
- [site](site) is built from the markdown in the `docs` directory using
  `make docs`.
