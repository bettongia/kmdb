# Contributing to KMDB

## Welcome

In terms of a code of conduct, it's pretty straight-forward: **Be kind or be
gone**.

This is a pretty small project so you should not expect anyone to jump to
attention and resolve your issue. Rather, it's open source so please fork it and
carry on.

## The Codebase

See the [LSM Primer](docs/primer.md) for a high-level overview of the storage
engine.

- The [`Makefile`](Makefile) encapsulates the main tasks such as building the
  project, running tests, building the docs etc.
- [docs](docs) contains the specifications and guides for this project. It's
  written in [Pandoc Markdown](https://pandoc.org/MANUAL.html).
- [site](site) is built from the markdown in the `docs` directory using
  `make docs`.

## Tricky things

### ZStandard library

The [`es_compression` package](https://github.com/instantiations/es_compression)
provides the ZStandard compression functionality but does not include (at time
of writing: 03-2026) an Apple Silicon-compatible copy of the library. As per
this [GitHub issue](https://github.com/instantiations/es_compression/issues/49)
we can compile our own.

Change into a useful directory and then run the following commands in order to
build the library:

```bash
brew install cmake
git clone git@github.com:instantiations/es_compression.git
mkdir build && cd build
cmake .. -G"Unix Makefiles"
make
```

Note: You can find the pre-packaged libs in
`~/.pub-cache/hosted/pub.dev/es_compression-2.0.15/lib/src/zstd/blobs/eszstd-mac64.dylib`.

### PDF generation of docs

This is purely a nice to have. In order to generate PDFs we need a LaTeX
toolchain and the DejaVu fonts:

```
brew install --cask mactex
sudo tlmgr update --self --all
sudo tlmgr paper a4
brew install --cask font-dejavu
```
