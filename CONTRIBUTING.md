# Contributing to KMDB

## Welcome

In terms of a code of conduct, it's pretty straight-forward: **Be kind or be
gone**.

This is a pretty small project so you should not expect anyone to jump to
attention and resolve your issue. Rather, it's open source so please fork it and
carry on.

## The Codebase

See [§1 System Overview](docs/spec/01_overview.md) for a high-level overview of
the storage engine and the rest of the system.

- The [`Makefile`](Makefile) encapsulates the main tasks such as building the
  project, running tests, building the docs etc.
- [docs](docs) contains the specifications and guides for this project. It's
  written in [Pandoc Markdown](https://pandoc.org/MANUAL.html).
- [site](site) is built from the markdown in the `docs` directory using
  `make docs`.

## Makefile

The default task is configured to provide useful tasks for development and you
can just run `make`.

To generate a release, use `make release` - you'll find the output in the `dist`
directory.

## Tricky things

### PDF generation of docs

This is purely a nice to have. In order to generate PDFs we need a LaTeX
toolchain and the DejaVu fonts:

```
brew install --cask mactex
sudo tlmgr update --self --all
sudo tlmgr paper a4
brew install --cask font-dejavu
```
