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
	# Serial (concurrency 1): under Dart 3.13 native assets stage to the shared
	# workspace-root .dart_tool/lib/, and two concurrent codesigns of the same
	# dylib (libonnxruntime.dylib) collide ("replacing existing signature"). See
	# the test_dart_serial script in pubspec.yaml. Linux keeps concurrency 2.
	melos test_dart_serial --no-select
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
	# Serial (concurrency 1): under Dart 3.13 native assets stage to the shared
	# workspace-root .dart_tool/lib/, and Windows cannot delete/restage a DLL
	# (zstd.dll) held loaded by a concurrent package's test process. See the
	# test_dart_serial script in pubspec.yaml. Linux keeps concurrency 2.
	melos test_dart_serial --no-select
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
#
# NOTE: a `flutter build macos` step to compile the Swift/SPM plugin
# end-to-end (release-ninja #3) is deliberately NOT here yet. When it was
# first added, it revealed that the kmdb_icloud macOS plugin does not resolve
# `FlutterFramework` in a fresh SPM build (`import Flutter` fails), so the
# native build + that fix were split into their own follow-up
# (plan_0_10_01_kmdb_icloud_macos_build.md). This lane stays Dart-only until
# that lands.
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
#
# The barrel-compile smoke (0.10.01 WI-9 Phase C, release-blocker #1) proves
# `package:kmdb/kmdb.dart` — the public API barrel — actually compiles for
# web via the `embedding_model.dart` seam. It, like the vault KAT test, must
# use `--compiler dart2wasm`: the barrel transitively includes the storage
# engine (XXH64), which hits the same dart2js int-literal rejection noted
# above. wasm-only per the plan's Q2 decision (dart2wasm is the sole
# supported web compiler for 0.1.0).
#
# The SAHPool adapter test (release-ninja #2) was, before this plan, never
# executed in any CI lane despite backing every "web LSM ✓ / Sync ✓" claim in
# §19 — wiring it in here is what makes those claims CI-verified rather than
# aspirational. Run under both the dart2js default and `--compiler
# dart2wasm`: a prior version of `_send`'s zero-copy buffer transfer silently
# detached the *caller's* own `Uint8List` after `writeFile`/`appendFile`
# under dart2js (not reachable under the wasm-only supported target, but
# cheap to guard defensively either way — see `storage_adapter_sahpool.dart`'s
# `_send` doc comment), so both compilers are kept here as a belt-and-braces
# regression fence.
#
# The web-platform-exclusion test asserts `KmdbDatabase.open` throws a clear
# `UnsupportedError` on web when `vecIndexes` is non-empty (semantic search
# is compile-time excluded on web — see docs/spec/22_semantic_search.md).
#
# The `StorageAdapterSahPool` barrel-export persistence test (0.10.01 WI-9
# Phase C, release-ninja finding #2) proves — through the public barrel
# import only — that a document written via `KmdbDatabase.open(adapter:
# StorageAdapterSahPool())` survives `close()` and reopen with a freshly
# constructed adapter at the same OPFS path. Must use `--compiler dart2wasm`
# for the same reason as the barrel smoke and vault KAT tests above: it
# transitively imports the storage engine (XXH64), which dart2js's front end
# rejects outright on the 64-bit prime int literals.
cicd_web:
	dart pub global activate melos
	melos bootstrap
	cd packages/kmdb && dart test --platform chrome test/encoding/value_codec_test.dart
	cd packages/kmdb && dart test --platform chrome --compiler dart2wasm test/vault/vault_hash_kat_test.dart
	cd packages/kmdb && dart test --platform chrome test/sync/auth/web_sync_authenticator_test.dart
	cd packages/kmdb && dart test --platform chrome --compiler dart2wasm test/web/kmdb_barrel_wasm_smoke_test.dart
	cd packages/kmdb && dart test --platform chrome test/engine/storage_adapter_sahpool_test.dart
	cd packages/kmdb && dart test --platform chrome --compiler dart2wasm test/engine/storage_adapter_sahpool_test.dart
	cd packages/kmdb && dart test --platform chrome --compiler dart2wasm test/query/kmdb_database_web_platform_test.dart
	cd packages/kmdb && dart test --platform chrome --compiler dart2wasm test/query/storage_adapter_sahpool_web_persistence_test.dart
.PHONY: cicd_web

# ── Publish dry-run gate ──────────────────────────────────────────────────────
#
# Runs `dart pub publish --dry-run` for every auto-published package
# (release-ninja #4, 0.10.01) so a future path-dependency slip, metadata
# error, or constraint regression is caught in CI instead of only when a
# human runs the real `dart pub publish` at release time. Mirrors
# docs/releasing/0.1.0.md Stage 2's six auto-published packages;
# `kmdb_flutter`/`kmdb_icloud` are `publish_to: none` (hand-published) and
# `kmdb_harness` is never published, so none of the three are in this matrix.
#
# Pass/fail contract (verified empirically against a real dry-run,
# 2026-09-01 — see the plan's Q3):
#   - Fail if the command's exit code is non-zero (genuine validation errors,
#     resolution/network failure).
#   - Also fail if the trailing summary line, `Package has N warnings and M
#     hints.`, reports a warnings count > 0 — warnings do NOT affect the exit
#     code, so exit-code-only checking would silently let them through.
#   - Ignore the hint count entirely. The root pubspec.yaml's
#     `dependency_overrides` (meta/uuid/cbor/web/charset) produce expected,
#     per-package "Non-dev dependencies are overridden" hints (not always 5 —
#     only overrides that participate in that package's own resolution are
#     reported) that must NOT fail the lane.
#   - If the summary line is absent (e.g. the command aborted before
#     validation), the non-zero exit code from the first bullet already
#     covers that case.
#
# No `melos bootstrap` needed: `dart pub publish --dry-run` resolves each
# package's own workspace member on its own.
cicd_publish_dryrun:
	@status=0; \
	for pkg in kmdb kmdb_cli kmdb_google_drive kmdb_extractor_pdf kmdb_extractor_html kmdb_extractor_markdown; do \
		echo "── dart pub publish --dry-run: $$pkg ──────────────────────────"; \
		out=$$(cd packages/$$pkg && dart pub publish --dry-run 2>&1); \
		code=$$?; \
		echo "$$out"; \
		if [ $$code -ne 0 ]; then \
			echo "FAIL: $$pkg — dart pub publish --dry-run exited $$code"; \
			status=1; \
			continue; \
		fi; \
		warnings=$$(echo "$$out" | grep -oE 'Package has [0-9]+ warnings? and [0-9]+ hints?\.' \
			| grep -oE '[0-9]+' | head -1); \
		if [ -z "$$warnings" ]; then \
			echo "FAIL: $$pkg — could not find the 'Package has N warnings and M hints.' summary line"; \
			status=1; \
			continue; \
		fi; \
		if [ "$$warnings" -gt 0 ]; then \
			echo "FAIL: $$pkg — $$warnings warning(s) reported"; \
			status=1; \
		else \
			echo "OK: $$pkg — 0 warnings"; \
		fi; \
	done; \
	exit $$status
.PHONY: cicd_publish_dryrun

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
