// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// @docImport 'secret_store.dart';
/// @docImport 'package:kmdb/src/query/kmdb_database.dart';

/// Number of leading hex characters of the SHA-256 database-scope digest used
/// as a key prefix — 32 hex chars = 128 bits, far beyond any realistic
/// collision risk for the handful of database directories on one machine.
const int _scopeHashLength = 32;

/// Derives a per-database-scoped [SecretStore] key from [dbDir] and [name].
///
/// A [SecretStore] instance may be shared across multiple databases (e.g. one
/// global store rooted at a per-user profile config directory), so a bare
/// [name] such as `'dek.wrap.biometric'` is not on its own collision-free:
/// two distinct databases on the same machine would otherwise silently
/// overwrite each other's secret under the same shared key.
///
/// This function closes that gap by prefixing [name] with a fixed-length
/// **hex SHA-256 digest** of [dbDir]'s canonicalised absolute path, so every
/// secret is implicitly namespaced by the database it belongs to. Used by the
/// core unlock-policy bootstrap (`KmdbDatabase.open`'s biometric-wrapped-DEK
/// and re-authentication-timestamp keys) and by any host that stores its own
/// per-database secrets in a shared [SecretStore].
///
/// ## Why a hash prefix rather than the readable path
///
/// An earlier design used the encoded path itself as the prefix and a `--`
/// delimiter. That is **not boundary-safe**: a directory name may legally
/// contain `--`, so a key for database `~/work--archive` (encoded prefix
/// `…work--archive`) has `…work--` as a prefix and would be mis-attributed to
/// a *sibling* database `~/work` — whose orphan-secret cleanup would then
/// delete it as "orphaned". The path encoding was also non-injective
/// (separators and `:` both collapsed to `_`, so `a/b` and `a:b` mapped to
/// the same prefix). A hex digest of the canonical path is both
/// **fixed-length and `-`-free**, so the single `-` delimiter is unambiguous,
/// and **injective** for distinct paths (SHA-256), closing both holes. The
/// cost is that a listing of stored keys shows a hash prefix rather than a
/// legible path — an acceptable trade for a mechanism whose whole job is to
/// never touch another database's secret.
///
/// [dbDir] does not need to exist on disk — canonicalisation here is purely
/// syntactic (`package:path`'s [p.absolute]/[p.normalize]), not a filesystem
/// call, so this works identically for a not-yet-created database directory.
String dbScopedSecretKey(String dbDir, String name) =>
    '${_dbScopeHash(dbDir)}-$name';

/// Returns `true` if [key] was produced by [dbScopedSecretKey] for [dbDir].
///
/// Used by callers that need to filter the (possibly multi-database) key list
/// returned by a shared [SecretStore] down to just the keys that belong to
/// one specific database. The match is unambiguous: the scope hash is
/// exactly [_scopeHashLength] hex characters with no `-`, so the first `-` in
/// a well-formed key always separates scope from name, and [name] (which
/// follows) may itself contain any character without affecting the match.
bool isSecretKeyForDb(String key, String dbDir) =>
    key.startsWith('${_dbScopeHash(dbDir)}-');

/// Canonicalises [dbDir] and returns the leading [_scopeHashLength] hex
/// characters of its SHA-256 digest.
String _dbScopeHash(String dbDir) {
  final canonical = p.normalize(p.absolute(dbDir));
  final digest = sha256.convert(utf8.encode(canonical));
  return digest.toString().substring(0, _scopeHashLength);
}
