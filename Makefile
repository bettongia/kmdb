.DEFAULT_GOAL := default

include make_release.mk make_site.mk

KMDB_PKG=packages/kmdb

# ADDLICENSE_CONFIG=addlicense_config.txt

default: prepare format analyze test license_check
.PHONY: default

#all: format analyze license_check coverage site
#.PHONY: all

# Pre-commit gate: formatting, static analysis, license headers, and the core
# test suites (kmdb + kmdb_cli). Deliberately excludes coverage, the docs site
# build, and `clean` (full clean + bootstrap) — too slow and side-effecting for
# a commit hook; those run in CI / via `make coverage` and `make site`.
#
# Tests run as two separate `dart test` invocations (not `melos test`) on
# purpose:
#   - it scopes the gate to the actively-developed core, keeping it fast;
#   - running each package sequentially in its own invocation avoids the
#     concurrent native-asset build race (shared betto_zstd dylib) that can
#     transiently fail `melos test`;
#   - kmdb_cli must run from its own directory so its build hooks fire.
# The full multi-package suite (incl. native-asset / Flutter packages) runs in
# CI and via `make test`.
pre_commit: format_check analyze license_check
	melos pre_commit_test --no-select
.PHONY: pre_commit

cicd: prepare format_check analyze license_check coverage benchmarks
.PHONY: cicd

analyze:
	melos run analyze
.PHONY: analyze

benchmarks:
	set -o pipefail; melos benchmarks --no-select 2>&1 | tee benchmarks.log
.PHONY: benchmarks

tests_all: test e2e_test
.PHONY: tests_all

test: test.log
.PHONY: test

test.log: packages/**
	set -o pipefail; melos test --no-select 2>&1 | tee test.log


e2e_test:
	melos e2e-test 2>&1
.PHONY: e2e_test

## Run Zstd web compression tests in Chrome (requires Chrome to be installed).
## Uses --no-sandbox so it works in CI Linux environments (see dart_test.yaml).
## Set CHROME_EXECUTABLE=chrome on Linux CI to point to the installed binary.
web_test:
	cd packages/kmdb && dart test --platform chrome test/encoding/value_codec_test.dart
.PHONY: web_test

license_check:
	melos licenses

license_add:
	melos licenses:add

.PHONY: license_add license_check

docs: site coverage
.PHONY: docs

coverage:
	mkdir -p site
	set -o pipefail; melos coverage 2>&1 | tee coverage.log

## Format all Dart sources under packages/ in place. Uses `dart format` directly
## (not `melos format`) to avoid the name collision with the `format` melos
## script and to cover the whole package tree (bin/, example/, benchmark/), not
## just lib/ and test/.
format:
	dart format packages
.PHONY: format

## Check formatting without modifying files. Fails if any file is unformatted —
## used by the pre-commit hook so the commit is blocked (rather than silently
## reformatting already-staged files). Mirrors `format`'s scope exactly.
format_check:
	dart format --output=none --set-exit-if-changed packages
.PHONY: format_check

prepare:
	dart pub global activate melos
	dart pub global activate coverage
	melos bootstrap
.PHONY: prepare

clean:
	melos clean_packages
	rm -rf site dist build coverage dist
	rm -f *.log
	melos clean
	melos bootstrap

scrub:
	melos scrub_packages
	rm -rf site dist build coverage dist
	rm -f *.log
	rm -rf .dart_tool
	melos clean
	melos bootstrap

.PHONY: clean scrub
