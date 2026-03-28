# Cache Layer

## Purpose

The Cache Layer wraps `KvStore` and sits between it and the Query Layer. It
provides two distinct caches:

1. **Session object cache** — recently decoded `Map<String, dynamic>` objects
   held in memory for the process lifetime.
2. **Materialised view cache** — persisted scan results in the `$cache` system
   namespace, surviving process restarts on mobile and web.

Application code holds a reference to the Cache Layer (via `KmdbDatabase`), not
to `KvStore` directly.

## Platform Tiers

The caching strategy differs by platform because mobile and web processes are
killed silently — an in-memory cache cannot be assumed to be warm on next open.

| Platform              | Session cache size | Persistent cache | Notes |
| :-------------------- | :----------------- | :--------------- | :---- |
| Desktop (macOS, Windows, Linux) | 2,000 objects | Optional — process is long-lived | Cache is built once on open and stays warm. |
| Mobile (iOS, Android) | 256 objects | Required | Process silently killed frequently. Must rebuild from `$cache` on cold open. |
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

Each user namespace has a generation counter stored in `$meta` under the key
`gen:{namespace}`. The counter increments by 1 on every successful `WriteBatch`
that touches that namespace. The counter is the universal invalidation signal
across all cache tiers.

- **On write:** the `WriteBatch` that writes the document also increments the
  generation counter for that namespace in the same atomic batch.
- **On read:** the Cache Layer reads the current generation from `$meta`. If the
  cached entry's generation matches, the cache is valid. If not, the entry is
  stale and must be re-fetched.
- **On sync:** when inbound SSTables from another device are ingested, the
  affected namespaces have their generation counters incremented, automatically
  invalidating stale cache entries on the next access.

## Materialised View Cache (`$cache`)

For expensive or frequently-used scans — a contact list, a task count by status,
the most recent notes — the result set is persisted as a CBOR-encoded list of
document keys in the `$cache` system namespace. Each entry includes the
generation counter at compute time.

**On access:** compare the stored generation against the current namespace
generation. If they match, return the cached key list and fetch documents by
key (fast point lookups, likely in the session cache).

**If stale:** on mobile and web, return the stale result immediately for
perceived performance, trigger a background re-scan, and notify the caller via
an `onCacheRefreshed` callback when the fresh result is ready. On desktop, block
and return the fresh result directly — in-memory is warm enough that the
serve-stale pattern adds unnecessary complexity.

**Cache key format:** `$cache:{namespace}:{queryHash}` where `queryHash` is a
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

1. Read the new generation counter for the affected namespace from `$meta`.
2. Evict all session cache entries for that namespace whose generation does not
   match the new counter.
3. Mark `$cache` entries for that namespace as potentially stale (checked lazily
   on next access).

This ensures the cache is always consistent with `KvStore` state without
requiring a full cache flush on every write.
