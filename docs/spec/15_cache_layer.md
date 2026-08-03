# Cache Layer

## Purpose

The Cache Layer wraps `KvStore` and sits between it and the Query Layer. It
provides two distinct caches:

1. **Session object cache** — recently decoded `Map<String, dynamic>` objects
   held in memory for the process lifetime.
2. **Materialised view cache** — persisted scan results in the `$$cache`
   local-only system namespace, surviving process restarts on mobile and web.
   (`$$cache` is currently unimplemented spec — see below.)

Application code holds a reference to the Cache Layer (via `KmdbDatabase`), not
to `KvStore` directly.

## Platform Tiers

The caching strategy differs by platform because mobile and web processes are
killed silently — an in-memory cache cannot be assumed to be warm on next open.

| Platform              | Session cache size | Persistent cache | Notes |
| :-------------------- | :----------------- | :--------------- | :---- |
| Desktop (macOS, Windows, Linux) | 2,000 objects | Optional — process is long-lived | Cache is built once on open and stays warm. |
| Mobile (iOS, Android) | 256 objects | Required | Process silently killed frequently. Must rebuild from `$$cache` on cold open. |
| Web (dart2js / WASM)  | 256 objects | Required | Every page reload is a cold start. No persistent process memory. |

The `CacheTier` is auto-detected from the platform at `KvStore.open()` time and
can be overridden in `KvStoreConfig`.

## Session Object Cache

The session cache holds recently decoded `Map<String, dynamic>` objects keyed by
`(namespace, key, sequenceNumber)`. The sequence number in the cache key means
stale entries are naturally invalidated when a document is written — the new
write produces a higher sequence number, and any cached entry with the old
sequence is never served again (it simply ages out of the LRU).

On desktop the cache holds 2,000 objects. On mobile and web it holds 256 —
enough for the currently visible UI and recently viewed items. The size is
configurable via `KvStoreConfig.sessionCacheMaxObjects`.

## Namespace Generation Counters

Each user namespace has a generation counter stored in the local-only
`$$genstate` system namespace under the key `gen:{namespace}`. The counter
increments by 1 on every successful local `WriteBatch` that touches that
namespace, and (see "On sync" below) on every ingest of a peer SSTable that
touches it. The counter is the universal invalidation signal across all cache
tiers.

> **Device-local, not synced (0.10.01 WI-13).** The counter used to live in
> synced `$meta`. `$meta` resolves by plain last-write-wins on HLC, so a
> peer's later-HLC-but-lower `gen` value could move the counter *backwards* —
> and because the session cache's key is `(namespace, key)` with `gen` stored
> as a match *field* (not part of the key), a gen mismatch produces a miss
> **without removing the stale entry**. A subsequent backwards move could
> then match the surviving stale entry's discriminator and resurrect it: the
> cache would serve data from before the newer writes (the underlying LSM
> data was always correct — this was a session-cache-only defect). Moving the
> counter to the local-only `$$genstate` namespace (never uploaded, never
> read from a peer) closes this. See `MetaStore.kGenStateNamespace`'s doc
> comment for the full mechanism.

- **On write:** the `WriteBatch` that writes the document also increments the
  generation counter for that namespace in the same atomic batch.
- **On read:** the Cache Layer reads the current generation from `$$genstate`.
  If the cached entry's generation matches, the cache is valid. If not, the
  entry is stale and must be re-fetched.
- **On sync (ingest):** because the counter is device-local, a peer's write
  never replicates a gen value in for this device to pick up — instead,
  `LsmEngine.ingestAt0` itself scans the ingested SSTable once for its
  distinct namespaces (reusing the already-open reader) and, for **exactly
  that set**, both bumps `$$genstate` and emits a per-namespace `writeEvent`.
  This is a *precise* scan (not an over-broad bump across every known
  namespace), matching the precision of the local `writeBatch` path — a
  cross-device sync therefore wakes only the namespaces it actually touched,
  never every registered namespace. The bump is written durably (WAL-fsynced)
  *before* the manifest edit that admits the ingested file, so a crash
  between the two leaves the counter bumped but the file un-admitted (a
  harmless spurious cache miss on next open) — never the reverse (new data
  visible under a stale counter).

## Materialised View Cache (`$$cache`)

For expensive or frequently-used scans — a contact list, a task count by status,
the most recent notes — the result set is persisted as a CBOR-encoded list of
document keys in the `$$cache` system namespace. Each entry includes the
generation counter at compute time.

> **Local-only, not synced (0.10.01 WI-13).** `$$cache` was previously
> classified single-`$` (syncable). A per-device materialised view of scan
> results must never sync — it is derived state specific to this device's
> query patterns and cache tier, exactly like `$$index:`/`$$fts:`/`$$vec:`.
> This is currently a spec-only correction: `$$cache` has no code writers yet
> (this cache tier is unimplemented), so no data migration is needed.

**On access:** compare the stored generation against the current namespace
generation. If they match, return the cached key list and fetch documents by
key (fast point lookups, likely in the session cache).

**If stale:** on mobile and web, return the stale result immediately for
perceived performance, trigger a background re-scan, and notify the caller via
an `onCacheRefreshed` callback when the fresh result is ready. On desktop, block
and return the fresh result directly — in-memory is warm enough that the
serve-stale pattern adds unnecessary complexity.

**Cache key format:** `$$cache:{namespace}:{queryHash}` where `queryHash` is a
deterministic hash of the query's filter, orderBy, limit, and offset parameters.

## Lifecycle Hook

On mobile and web, `KmdbDatabase.onResume()` must be called when the app returns
to the foreground. This triggers the Cache Layer to check namespace generation
counters against any sync that occurred while the app was suspended, and
proactively invalidate stale entries before the first UI read.

```dart
// Flutter: wire into the app lifecycle observer
class _AppState extends State<App> with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      db.onResume(); // Cache Layer checks generation counters
    }
  }
}
```

## Cache Invalidation via `writeEvents`

The Cache Layer subscribes to `KvStore.writeEvents`. On each emission:

1. Read the new generation counter for the affected namespace from
   `$$genstate`.
2. Evict all session cache entries for that namespace whose generation does not
   match the new counter.
3. Mark `$$cache` entries for that namespace as potentially stale (checked
   lazily on next access).

`writeEvents` emissions for `$`-prefixed system namespaces (e.g. `$meta`,
`$sync`) are ignored by this handler — only bare user-namespace events (local
writes, or an ingest's per-namespace emit) trigger eviction.

This ensures the cache is always consistent with `KvStore` state without
requiring a full cache flush on every write.
