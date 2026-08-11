# ── CI/CD Makefile targets ────────────────────────────────────────────────────
#
# These targets are intended for CI runners, not local development.  Local
# development uses `make pre_commit` (fast gate) and `make test` (full suite).
#
# Quality checks (format, analyze, license) run only in cicd_linux to avoid
# redundant work on every platform.  macOS and Windows verify that the test
# suite passes on their respective native file systems and with their native
# betto_zstd dylib/DLL.
#
# Web runs the WASM compression tests in Chrome.
#
# Each platform target is self-contained: it bootstraps the workspace, then
# runs its checks.  This mirrors the Bettongia CI pattern of driving CI from
# the Makefile so that local reproduction of any CI failure requires only the
# matching `make cicd_*` invocation.

# ── Linux base ────────────────────────────────────────────────────────────────
#
# Core quality gate: format check, analysis, license check, tests (via
# coverage), 90% line-coverage threshold, and benchmarks.
#
# Does NOT require pandoc — safe to run in the local Podman container where
# the distro pandoc is too old.  Used directly by `container_cicd` and as a
# prerequisite for `cicd_linux`.
cicd_linux_base:
	dart pub global activate melos
	dart pub global activate coverage
	melos bootstrap
	dart format --output=none --set-exit-if-changed \
		packages/kmdb packages/kmdb_cli packages/kmdb_harness \
		packages/kmdb_google_drive packages/kmdb_flutter \
		packages/kmdb_extractor_pdf packages/kmdb_extractor_html \
		packages/kmdb_extractor_markdown
	melos run analyze
	cat addlicense_config.txt | xargs addlicense --check
	melos coverage
	@pct=$$(lcov --summary site/coverage/lcov.info 2>&1 \
	  | grep 'lines\.\.\.\.' | grep -oE '[0-9]+\.[0-9]+' | head -1); \
	echo "Line coverage: $${pct:-unknown}%"; \
	if [ -z "$$pct" ]; then \
	  echo "ERROR: could not parse line coverage from lcov output"; \
	  exit 1; \
	fi; \
	awk -v p="$$pct" \
	  'BEGIN { if (p+0 < 90) { printf "FAIL: %.1f%% line coverage is below the 90%% minimum\n", p+0; exit 1 } }'
	melos benchmarks --no-select 2>&1 | tee benchmarks.log
.PHONY: cicd_linux_base

# ── Linux ─────────────────────────────────────────────────────────────────────
#
# Full Linux CI gate: base quality checks + HTML doc site build.
# Requires pandoc (installed via pandoc/actions/setup in GitHub Actions).
# Run by GitHub Actions; local container developers use `make container_cicd`
# which targets `cicd_linux_base` instead.
cicd_linux: cicd_linux_base
	$(MAKE) doc_site_html
.PHONY: cicd_linux

# ── macOS ─────────────────────────────────────────────────────────────────────
#
# Verifies that Dart tests pass on the macOS file system and that the
# betto_zstd native dylib builds and links correctly on arm64/x86_64.
# Skips quality checks (format/analyze/license) — those run in cicd_linux.
# kmdb_icloud (Flutter plugin) is tested separately via cicd_icloud.
cicd_macos:
	dart pub global activate melos
	dart pub global activate coverage
	melos bootstrap
	melos test_dart --no-select
.PHONY: cicd_macos

# ── Windows ───────────────────────────────────────────────────────────────────
#
# Verifies that Dart tests pass on the Windows file system and that the
# betto_zstd DLL builds and loads correctly.
# Run with `shell: bash` in the GitHub Actions workflow.
cicd_windows:
	dart pub global activate melos
	dart pub global activate coverage
	melos bootstrap
	melos test_dart --no-select
.PHONY: cicd_windows

# ── iCloud Flutter plugin ─────────────────────────────────────────────────────
#
# Verifies the kmdb_icloud Flutter plugin and its example app: bootstraps both
# packages, format-checks Dart sources, analyzes, and runs the unit tests
# (harness convergence tests via FakeICloudSyncChannel).  e2e tests that
# require a real CloudKit container are credential-gated and skip automatically.
# Requires the Flutter SDK — run on macOS only.
# License check is intentionally omitted: addlicense covers the full repo in
# cicd_linux_base (it runs from the workspace root).
cicd_icloud:
	cd packages/kmdb_icloud && flutter pub get
	cd packages/kmdb_icloud/example && flutter pub get
	dart format --output=none --set-exit-if-changed \
		packages/kmdb_icloud/lib packages/kmdb_icloud/test packages/kmdb_icloud/example/lib
	cd packages/kmdb_icloud && flutter analyze
	cd packages/kmdb_icloud/example && flutter analyze
	cd packages/kmdb_icloud && flutter test
.PHONY: cicd_icloud

# ── kmdb_flutter package ──────────────────────────────────────────────────────
#
# Verifies the kmdb_flutter add-on package: bootstraps, format-checks Dart
# sources, analyzes, runs unit tests with coverage, and enforces the ≥ 90%
# line-coverage threshold (≥ 95% is the target for this small package).
# Requires the Flutter SDK — run on macOS only (same lane as cicd_icloud).
# License check is intentionally omitted: addlicense covers the full repo in
# cicd_linux_base (it runs from the workspace root).
cicd_flutter:
	cd packages/kmdb_flutter && flutter pub get
	dart format --output=none --set-exit-if-changed \
		packages/kmdb_flutter/lib packages/kmdb_flutter/test
	cd packages/kmdb_flutter && flutter analyze
	cd packages/kmdb_flutter && flutter test --coverage
	@pct=$$(lcov --summary packages/kmdb_flutter/coverage/lcov.info 2>&1 \
	  | grep 'lines\.\.\.\.' | grep -oE '[0-9]+\.[0-9]+' | head -1); \
	echo "kmdb_flutter line coverage: $${pct:-unknown}%"; \
	if [ -z "$$pct" ]; then \
	  echo "ERROR: could not parse line coverage"; exit 1; \
	fi; \
	awk -v p="$$pct" \
	  'BEGIN { if (p+0 < 90) { printf "FAIL: %.1f%% < 90%% minimum\n", p+0; exit 1 } }'; \
	awk -v p="$$pct" \
	  'BEGIN { if (p+0 < 95) { printf "WARN: %.1f%% is below the 95%% target\n", p+0 } }'
.PHONY: cicd_flutter

# ── Web / Chrome ───────────────────────────────────────────────────────────────
#
# Runs the WASM compression codec tests in Chrome, plus the vault SHA-256/
# CRC32C known-answer-vector tests (S-5, 0.10.01) — the latter guards against
# web (JS number) `int`-semantics divergence in the vault content-address
# hash. Requires Chrome to be installed and CHROME_EXECUTABLE=chrome to be
# set in the environment (handled by browser-actions/setup-chrome in the
# workflow).
#
# The vault test is compiled with `--compiler dart2wasm`, not the `dart2js`
# default: it transitively imports `xxhash.dart`, whose 64-bit prime
# constants are int literals that dart2js's front end rejects outright
# ("can't be represented exactly in JavaScript") because they exceed JS's
# 2^53 safe-integer range — see that file's "dart2js is not supported by
# KMDB" doc note. `value_codec_test.dart` never reaches that code path, so it
# stays on the dart2js default.
#
# The sync-auth test (0.10.01 WI-4 T1) exercises WebSyncAuthenticator's real
# WebCrypto (SubtleCrypto) + IndexedDB code paths — the only way to verify
# that implementation is "realisable, not hand-waved" per the plan's Q4
# design record. It includes a known-answer-vector cross-check against
# DefaultSyncAuthenticator's native derivation (see
# default_sync_authenticator_test.dart's matching KAT test).
cicd_web:
	dart pub global activate melos
	melos bootstrap
	cd packages/kmdb && dart test --platform chrome test/encoding/value_codec_test.dart
	cd packages/kmdb && dart test --platform chrome --compiler dart2wasm test/vault/vault_hash_kat_test.dart
	cd packages/kmdb && dart test --platform chrome test/sync/auth/web_sync_authenticator_test.dart
.PHONY: cicd_web

# ── Container (Podman) ─────────────────────────────────────────────────────────
#
# Runs cicd_linux inside a Linux container — useful for Mac/Windows developers
# who want to reproduce the Linux CI environment locally without a VM.
#
# `container_cicd` is a clean-room run: pub packages are downloaded fresh each
# time, matching what CI does.  For faster repeated runs, create a named volume
# so Podman manages ownership correctly:
#
#   podman volume create kmdb-pub-cache
#   podman run --rm -v kmdb-pub-cache:/home/runner/.pub-cache kmdb-cicd
#
# A host bind-mount (-v ~/.pub-cache:...) is intentionally avoided: on macOS
# the Podman VM does not remap UIDs, so the container's `runner` user cannot
# write to a directory owned by the host user.
container_build:
	podman build -t kmdb-cicd .
.PHONY: container_build

container_cicd: container_build
	podman run --rm kmdb-cicd
.PHONY: container_cicd
