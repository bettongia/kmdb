# Technical Proposal: KMDB Server

## 1. Overview

KMDB is a local-first document database: data lives on the device, sync is
additive, and every device is a full peer (§12). Two capabilities strain that
model on thin clients:

- **Semantic and hybrid search (§22–23)** require an ONNX embedding model and an
  SQ8 vector index. Running the model and holding the vector index is heavy for
  a phone, and is **not available on web at all** (§20 excludes web from
  semantic search and the vault). A mobile or web UI therefore cannot offer the
  same search a desktop can.
- **The vault (§24)** can hold large blobs. A thin client may not want to
  replicate every blob, and web clients cannot run the native extraction/index
  pipeline (vault_search proposal §9).

This proposal explores a **KMDB server**: a headless process that wraps one or
more `KmdbDatabase` instances and exposes their functionality — document CRUD,
lexical/semantic/hybrid search over documents *and* the vault, and vault blob
streaming — to lightweight clients over the network. The server hosts the
"bulky" elements (embedding model, vector index, vault storage) so a thin client
does not have to.

A secondary role is **sync participation** (§12): the server can act as a sync
target other devices sync through, and/or sync onward to a cloud store on the
user's behalf.

### The deployment model this targets

This is **explicitly not a centralized SaaS.** The target is **self-hosted**: a
user runs the server on hardware they control — a home NAS, a Raspberry Pi, a
VPS — the same way people self-host Nextcloud, Immich, Home Assistant, a Matrix
homeserver, or a Syncthing node. **Multi-tenancy is in scope**: one server
process may host multiple users' KMDB instances (a family or small group sharing
one box, or a hobbyist hosting friends). [Solid][solid] is a philosophical
reference point — user-owned data under a decentralized identity — but its
identity protocol is not adopted wholesale (§7.3).

Because the server hosts multiple users' data, it raises an isolation
requirement stronger than usual: the server must prevent one tenant from ever
reading another tenant's data or vault, **not merely resist external
attackers**. Combined with KMDB's encryption model (§31), this creates a
first-class design tension — what does it even *mean* for a server to index and
search data it may not be able to decrypt? — that §5 addresses head-on rather
than glossing.

> **Status.** This is a pre-planning exploration. There is **no** prior server,
> remote-access, or multi-tenancy work anywhere in the repo — this is genuinely
> greenfield. It is not yet a plan; §10 lists the decisions needed from the
> project owner before it can become a `docs/plans/` entry.

### Goals

- Let a thin mobile/web client run lexical, semantic, and hybrid search
  (documents and vault) it cannot run locally, by delegating to a server.
- Let a thin client stream vault blobs on demand without replicating them.
- Support self-hosting on modest hardware (NAS/Pi/VPS) with a hobbyist-grade
  operational burden.
- Support optional multi-tenancy with a **defensible** cross-tenant isolation
  boundary.
- Reuse KMDB's existing primitives (the `SyncStorageAdapter` shape, the vault
  store, `FtsManager`/`VecManager`, the value pipeline) rather than re-rolling
  them.
- Keep single-user self-hosting simple: none of the multi-tenant machinery
  should be mandatory for a one-person deployment.

### Non-goals (v1)

- A hosted/managed KMDB cloud offering. Self-hosted only.
- Zero-knowledge search offload — searching data the server cannot decrypt.
  §5 explains why this is not achievable under the current value-level scheme
  and is deliberately out of scope.
- Turning the sync protocol into a client/server protocol. Sync stays
  peer-to-peer with a dumb blob store (§12); the server is an *additional*
  participant, not a replacement coordinator.
- Federation between KMDB servers (à la Matrix). A single self-hosted server is
  the unit; cross-server federation is future work (§11).
- Real-time collaborative editing / CRDTs. Conflict resolution remains
  LWW-by-HLC (§12).
- Web support for the *server's own* embedding/index build. The server is
  native-only (§3.5); it is precisely what lets a *web client* get semantic
  search without running the model itself.

---

## 2. Prior Art

Self-hosted, user-owned servers are a mature category. The lessons that bear
directly on this design:

| System | Multi-tenant isolation | Auth | Network exposure | What KMDB should borrow / avoid |
| :-- | :-- | :-- | :-- | :-- |
| **[Nextcloud AIO][nc]** | Strong deployments run **separate instances per tenant** (rootless-Docker-per-user or per-VM); logical "path-based" isolation is the weaker fallback | Admin-provisioned local accounts; optional OIDC/LDAP | Reverse proxy (nginx/Caddy) + TLS, or VPN | **Borrow:** container/instance-per-tenant as the real isolation story. **Avoid:** relying on in-process logical separation for security |
| **[Immich][immich]** | Multi-user in one app, but the **heavy ML runs as its own separate service/container** | Local accounts; OAuth optional | Reverse proxy or Tailscale | **Borrow:** split the heavy ML (embeddings) out as a separable process; treat it as a resource-bounded worker |
| **[Matrix / Synapse][synapse]** | One homeserver hosts many accounts; **federation** lets servers act as sync points for each other | Admin-provisioned accounts; registration policy is the operator's call | Reverse proxy; federation port | **Borrow:** the "server as a sync point others reach through" mental model, and admin-provisioned accounts. **Note:** Postgres becomes mandatory past ~10 users — a scaling cliff to keep in mind |
| **[Solid / Community Solid Server][css]** | Pod-per-user; WebID identity | **WebID-OIDC** decentralized identity | Reverse proxy | **Borrow:** the *philosophy* (user owns their data store). **Avoid:** WebID-OIDC ceremony — it solves cross-provider SSO a home server does not have (§7.3) |
| **Syncthing** | No accounts; device-keypair trust | Per-device TLS keypairs; manual device approval | Direct P2P / relay | **Borrow:** per-device identity/approval as a lightweight auth model that fits local-first |
| **[Cloudflare Workers][cf]** (isolation reference) | **V8 isolates**, many per process | — | — | **Cautionary:** even Cloudflare documents isolates as a *weaker* boundary than processes/VMs, disables `SharedArrayBuffer` + high-res timers for Spectre, and **falls back to process isolation for high-security tenants** (§6) |
| **[Tailscale / WireGuard][ts]** (exposure reference) | — | Network-layer device identity | **Mesh VPN, no open ports** | **Borrow:** the strong self-hosting consensus — prefer a WireGuard/Tailscale mesh over port-forwarding a reverse proxy (§7.1) |

Two cross-cutting takeaways:

1. **Nobody serious relies on in-process logical isolation as the security
   boundary for untrusted-adjacent multi-tenant data.** The strong deployments
   use OS processes, containers, or VMs. This directly informs §6.
2. **Searchable encryption does not rescue the zero-knowledge case.** The
   literature is consistent: server-side search over ciphertext the server
   cannot decrypt is either impossible (semantic/vector) or research-grade with
   severe expressiveness/security tradeoffs (blind indexing / SSE, exact-match
   only). This informs §5.

---

## 3. Grounding in KMDB's Architecture

Five facts about the current system (verified against `main`, not just the spec)
constrain every option below. They are stated up front because several
"obvious" server designs are ruled out by them.

### 3.1 Sync is a dumb blob store

The sync backend interface is **`SyncStorageAdapter`**
(`packages/kmdb/lib/src/sync/sync_storage_adapter.dart`, §12 "Adapter
Contract"). It is a passive object store:

```dart
Future<List<String>> list(String remoteDir, {String? extension, SyncContext? ctx});
Future<Uint8List?>   download(String remotePath, {SyncContext? ctx});
Future<void>         upload(String remotePath, Uint8List bytes, {SyncContext? ctx});
Future<void>         delete(String remotePath, {SyncContext? ctx});
Future<bool>         compareAndSwap(String path, Uint8List newBytes,
                        {String? ifMatchEtag, SyncContext? ctx});
Future<String?>      getEtag(String path, {SyncContext? ctx});
bool get providesAtomicCas;
```

All coordination — high-water marks, LWW-by-HLC conflict resolution,
consolidation — is **client-side** (§12 opens: *"a peer-to-peer protocol with no
central server"*). The adapter never interprets file contents. The only
conditional-write primitive is `compareAndSwap`, used solely for the
`.consolidation-lease`; an adapter that cannot honour CAS sets
`providesAtomicCas = false`, and consolidation is skipped for everyone using it.

### 3.2 Derived indexes are local-only — the load-bearing fact

On `main` today, the `$$fts:*`, `$$vec:*`, and `$$index:*` namespaces are
**local-only and never synced**. `isLocalOnly(ns) => ns.startsWith(r'$$')`
(`namespace_codec.dart`); flush partitions the memtable into `.local.sst`
(never uploaded) vs regular `.sst`; `SyncEngine.push` filters local-only files
out of both upload and the HWM fold. §20 states it verbatim: the `$$` namespaces
are *"never uploaded to the sync folder … Each receiving device rebuilds these
indexes from the synced document data."*

**Consequence — this is the single most important architectural fact for this
proposal:** *"build the vector index once on the server and ship it to thin
clients"* is **not achievable through the sync mechanism.** The index lives in
`.local.sst`, is excluded from upload, and never travels. A server that is a
sync peer (§4.2) receives only raw documents and rebuilds its own index like any
other device.

The index can only reach a thin client as **query results over an API** — the
server holds the index locally and answers queries; the index itself never
leaves the server. That is exactly the shape of §4.3, and it is *why* the
offload use case needs a query API rather than a sync trick.

### 3.3 Encryption is value-level; the DEK is required to index anything

Encryption (§31) is **value-level** AES-256-GCM: keys stay plaintext, values are
ciphertext. The DEK is wrapped (Argon2id-from-passphrase or HKDF-from-recovery-
code) into an `enc:blob` record in `$meta` that bypasses `ValueCodec`; a device
unlocks by reading `enc:blob`, deriving the KEK from the user secret, unwrapping
the DEK, and holding it in process memory (`DekCache`) for the DB's lifetime.

Critically: **`FtsManager` and `VecManager` decrypt the source document before
tokenising/embedding it** (`fts_manager.dart`, `vec_manager.dart`). Index
construction fundamentally requires plaintext. Therefore:

> **A server holding only ciphertext SSTables and no DEK cannot build or serve
> any search index. No DEK → no plaintext → no index, full stop.**

This is the crux of §5. (An in-flight defect, plan_0_08, is reconciling whether
the derived-index *values* are themselves encrypted; it does not change this
analysis, because those namespaces are local-only and never leave the device
regardless.)

### 3.4 Vault: whole-blob, plaintext-addressed, ciphertext-stored

The vault has a separate `VaultStorageAdapter`
(`uploadVaultObject`/`syncVaultMetadata`/`hydrateVaultBlob`/`vaultObjectExists`).
Devices sync **stubs** (`manifest.json` only) and hydrate blob bytes on demand
(§24). Two constraints matter for an API:

- The current hydrate API returns a **whole-blob `Uint8List`, not a stream.**
  True HTTP range-streaming is net-new work.
- When encryption is on, the **SHA-256 content address is computed over
  plaintext** but the stored bytes are `nonce || AES-GCM(dek, plaintext) ||
  tag`. The GCM tag can only be verified after reading the whole ciphertext, so
  a **DEK-less relay can only stream opaque whole blobs, never a plaintext
  byte-range.** A DEK-holding server can decrypt and then range-stream plaintext.

### 3.5 Platform: pure-Dart headless, native-only for the heavy parts

Core `kmdb` is **pure Dart with no Flutter dependency**; on Linux it gets the
`dart:io` native platform export, and `kmdb_cli` already proves headless
operation. `kmdb_flutter` (Flutter secure-storage DEK cache) and `kmdb_icloud`
are Flutter/Apple-only and irrelevant to a server — it uses `InMemoryDekCache`
or a custom `DekCache` (OS keyring / env-injected key). ONNX semantic search
runs headless via `betto_inferencing` → `betto_onnxrt`'s native-assets build
hook, which works in a `dart compile exe` binary. But **semantic search and the
vault are native-only (no web)** — so the server binary must target native, and
its build must fire the native-assets hook from inside the package dir (per the
CLAUDE.md native-asset-hooks note). This is a feature, not a limitation: the
server is what brings semantic search to web clients that cannot run it.

---

## 4. Integration Models

There are three distinct shapes a server can take. They are not mutually
exclusive; the recommendation is a primary shape with an optional companion.

### 4.1 Model A — Server as a `SyncStorageAdapter` (file-store / backup relay)

The server exposes an HTTP object-store endpoint; a client points a **new
`HttpSyncStorageAdapter`** at it (same shape as `kmdb_google_drive` /
`kmdb_icloud`, §29–30). The server holds SSTable bytes + HWM + lease and does
**zero** query work.

- **Implements:** `SyncStorageAdapter` (the 7 members in §3.1), validated by
  `runSyncAdapterConformance`. Must honour the CAS contract (a mutex or
  conditional-PUT) and return `providesAtomicCas = true`, or cross-device
  consolidation is disabled for all its users.
- **Trust:** can be **zero-knowledge** — it only ever sees ciphertext SSTables
  (§5, Option 2). Encryption metadata (namespace names, filenames, key
  timestamps) leaks per §31's documented gaps, but no plaintext.
- **Does NOT give the offload use case.** The client still needs the SSTables
  locally to answer queries. This is a backup target / sync transport, useful in
  its own right (a self-hosted alternative to Google Drive/iCloud that the user
  fully controls), but it is not "search on the server."

### 4.2 Model B — Server as a sync peer device

The server runs a full `KmdbDatabase`, calls `db.sync()` against the shared
folder like any other device, ingests everyone's SSTables, and rebuilds its own
`$$fts:`/`$$vec:` indexes locally.

- **Implements:** no sync interface — it *consumes* the existing
  `KmdbDatabase` sync API (`ensureDeviceId`, `sync`/`push`/`pull`).
- **Trust:** to rebuild indexes it must decrypt documents → it must hold the DEK
  (§5, Option 1).
- **Value:** keeps a server-side replica warm and consolidated; a natural base
  for Model C. On its own it still cannot *ship* the index (§3.2) — it needs a
  query API to expose it.

### 4.3 Model C — Server as a query / search API (the offload model) — RECOMMENDED PRIMARY

The server holds the authoritative (or a replica) `KmdbDatabase`, builds the
vector index locally, and exposes **query and search endpoints** to thin
clients. The thin client sends a query and receives ranked results; it never
holds the model or the index.

- **Implements:** a **net-new application-level API** (§8). No existing interface
  covers this — it is greenfield surface.
- **Trust:** requires the DEK to build/serve the index (§5, Option 1). This is
  the "trusted box" posture.
- **Value:** this is the **only shape that satisfies the actual motivating use
  case** — a web/mobile client getting semantic/hybrid search and vault search
  it cannot run locally. Everything else in §1's Goals flows from here.

### 4.4 Recommendation

**Adopt Model C as the primary shape**, because it is the only one that delivers
the motivating capability (§3.2 forecloses shipping the index; only serving
*results* works). Model C can be layered on a Model B replica (the server syncs
as a peer to stay current, then serves queries). Model A is a worthwhile
**optional companion** — a self-hosted, zero-knowledge sync/backup target for
users who want file custody without server-side search — and can ship
independently since it touches no core code.

The tradeoff to flag loudly (and carried to §10): **Model C requires the server
to hold the tenant's DEK and see plaintext.** Model A does not. A user choosing
C is trading zero-knowledge-against-their-own-server for server-side search.
That is a legitimate choice for a box you own — but it is a choice, and for
multi-tenant hosting it is a significant one (§5.4, §6).

---

## 5. The Encryption / Indexing Trust Tension

This is the hardest question in the proposal and the one most likely to shape
the product. It follows inexorably from §3.3: **to index or search, the server
needs plaintext; to have plaintext, it needs the DEK.**

### 5.1 Option 1 — Trusted, DEK-holding server (required for search offload)

The server unlocks each database with its passphrase/recovery code exactly like
any device, holds the DEK in process memory, decrypts documents, builds
`$$fts:`/`$$vec:` locally, and serves query results.

- **Enables:** the full offload use case (Model C), vault text extraction/search
  (§3.4), everything in §1's Goals.
- **Threat-model cost:** §31's threat model explicitly does **not** defend
  against a process that can read KMDB's memory. A DEK-holding server is exactly
  such a process. For a **single-user self-hosted box the user owns, this is
  entirely defensible** — the user already trusts the hardware their data lives
  on. It is philosophically the same trust a desktop app has.
- **How the server gets the DEK** is itself an open question (§10): the operator
  supplies it at service start (env/keyring), or each client supplies its
  passphrase on connect and the server caches the DEK for the session, or the
  database is simply not encrypted on a box the user deems physically trusted.

### 5.2 Option 2 — Zero-knowledge relay (no search)

The server never receives the DEK and only ever stores/relays ciphertext
SSTables and opaque vault blobs (Model A). It is a pure custody/backup/transport
target.

- **Enables:** self-hosted sync and backup with true zero-knowledge, at the
  strength of §31 (metadata leaks documented there still apply).
- **Cannot do:** any search, any query, any vault text extraction. Full stop.

### 5.3 Option 3 — Searchable encryption / blind indexing (rejected for v1)

In principle the server could hold an encrypted index built client-side and
answer queries over ciphertext (searchable symmetric encryption, blind
indexing). Rejected because:

- It only works for **exact-match / keyword equality**, not BM25 ranking and
  emphatically not dense-vector semantic search — the literature is clear that
  vector similarity over data the server cannot decrypt is research-grade.
- It would require the **thin client to build the index** — but the whole point
  of the server is that the thin client *cannot* run the embedding model. The
  approaches are fundamentally at odds.
- No mature Dart implementation exists; it would be a large, bespoke crypto
  subsystem with real footgun surface, contradicting the "reuse primitives"
  principle.

It is noted for completeness and left to future work if a keyword-only,
zero-knowledge search tier is ever wanted.

### 5.4 The multi-tenant amplification

For a **single tenant**, Option 1 is one DEK in one process the user owns —
benign. For **multi-tenant** hosting, Option 1 means **every tenant's DEK is
resident in the host process (or host machine) simultaneously**, and the
operator (or anyone who compromises the box) is trusted with every tenant's
plaintext. This is a materially stronger statement than "I trust my own NAS," and
it is the reason §6 insists the tenant boundary be a real OS boundary, not an
in-process one. **This — the DEK-in-server trust posture for multi-tenant
hosting — is the central security decision of the whole proposal, not a
footnote.** It is the first item in §10.

---

## 6. Multi-Tenancy and Isolation — the Isolate Question, Resolved

The starting-sketch draft proposed **Dart Isolates as the multi-tenant security
boundary** (one isolate per user, spun up on demand, killed after idle — the
"Hotel Model"), on the grounds that isolates share no heap. **This proposal
rejects isolates as the tenant *security* boundary.** They remain useful as an
intra-tenant concurrency tool; they are not a defensible isolation primitive for
untrusted-adjacent multi-tenant data.

### 6.1 Why isolates are not a sufficient security boundary

1. **They share one OS process and address space.** Isolate heaps are logically
   separate, but a single Dart VM bug (use-after-free, buffer overrun, a GC
   defect) reads across the whole process. There is no hardware boundary.
2. **The Dart VM has had none of the adversarial hardening V8 has.** Even
   Cloudflare — whose entire business depends on isolate density — documents V8
   isolates as a *weaker* boundary than processes/VMs, disables
   `SharedArrayBuffer` and high-resolution timers to blunt Spectre-class side
   channels, and **falls back to process isolation for high-security tenants.**
   Dart isolates have received no comparable Spectre mitigation. Betting a
   stronger isolation guarantee than Cloudflare claims, on a runtime with less
   hardening, is not defensible.
3. **Decisive: the heavy path runs in native code with full process memory
   access.** The embedding model and vector ops run through `betto_onnxrt` — a
   native C++ runtime invoked via FFI. **FFI code has no isolate boundary at
   all**; native code called from any isolate can read the entire process
   address space, including every other tenant's DEK and decrypted plaintext.
   The moment tenant A's request enters ONNX, the isolate boundary is
   irrelevant. This alone sinks isolates-as-security-boundary for a server whose
   defining feature is native embedding.
4. **The real threat here is not untrusted *code*.** Tenants upload data, not
   code, so the "isolates run untrusted code safely" framing is misapplied. The
   real risks are a confused-deputy/wrong-DEK routing bug and cross-tenant memory
   disclosure — both of which a process boundary contains and an isolate boundary
   does not (a per-process DEK lives in a separate address space a bug in another
   tenant's process cannot reach).

### 6.2 Recommended boundary: process-per-tenant (minimum), container-per-tenant (preferred)

- **Process-per-tenant** is the minimum defensible boundary: OS-enforced address
  space separation, per-tenant DEK confined to its own process, crash isolation.
- **Container-per-tenant** (rootless Docker / systemd-nspawn) is preferred for a
  real hosting scenario, matching what Nextcloud AIO and Immich actually do:
  add cgroup resource limits (cap a runaway embedding job), filesystem
  namespacing (a tenant's DB directory is unreachable from another container),
  and a seccomp profile. This is also the natural packaging unit (§9).
- **A supervisor/router process** owns the public listener, authenticates the
  request, maps it to a tenant, and forwards to that tenant's worker over a local
  socket. The router **never holds any tenant's DEK** — DEKs live only in worker
  processes.

The draft's **"Hotel Model" lifecycle is worth keeping — at process/container
granularity, not isolate granularity.** Lazily start a tenant's worker on first
request; tear it down after idle to reclaim RAM. The cost to price in: a cold
start now includes an **Argon2id unlock (~300–500ms) plus loading the ONNX model
and warming the vector index**, so the idle timeout wants to be minutes, not
seconds, and the model can be memory-mapped/shared read-only across workers to
cut per-tenant footprint (§9).

### 6.3 Single-tenant deployments pay none of this

For a one-person self-host, there is one database, one process, one DEK — the
isolation machinery is simply not instantiated. The multi-tenant boundary must
be **opt-in and absent by default**, so the common case stays a single boring
binary.

---

## 7. Network Exposure and Authentication

The draft mandated HTTP/3 + WebID-OIDC. Both are reconsidered against what a
self-hosted, single-operator box actually needs.

### 7.1 Exposure: prefer a mesh VPN over port-forwarding

The self-hosting consensus is strong: **prefer a WireGuard/Tailscale mesh (no
open inbound ports) over port-forwarding a reverse proxy.** Recommended posture:

- **Primary:** the server binds to a private interface and is reached over
  **Tailscale/WireGuard**. No ports are exposed to the internet; NAT traversal
  and transport encryption are handled by the mesh; device identity is
  established at the network layer (usable as an auth signal, §7.3).
- **Alternative:** a reverse proxy (Caddy/nginx/Traefik) terminating TLS for
  operators who want a public hostname, with the documented caveat that this
  opens an attack surface the mesh approach avoids.

The server should be **agnostic to which** — it speaks plain HTTP on a local
interface and lets the operator choose the exposure layer. It should **not**
ship its own TLS/QUIC stack as a hard requirement.

### 7.2 Transport: boring HTTP, not mandatory HTTP/3 or gRPC

- **HTTP/1.1 or HTTP/2 + REST** over a `shelf`/`dart_frog` server is more than
  adequate behind a mesh or reverse proxy. HTTP/3's headline benefits (0-RTT,
  seamless Wi-Fi↔cellular migration) are marginal for a home server reached over
  a stable WireGuard tunnel, and a QUIC stack is real complexity for a hobbyist
  binary. **Do not mandate HTTP/3.** (A reverse proxy can offer HTTP/3 to the
  client edge for free if wanted, with no server change.)
- **gRPC is not required and is a poor fit for the web target** — it needs a
  grpc-web proxy in browsers, which a Flutter-web thin client would have to
  carry. Plain HTTP + JSON works in every browser out of the box.
- **Payload efficiency** where it matters (search result batches, sync frames)
  is better served by **CBOR bodies** — KMDB already uses CBOR everywhere via
  `ValueCodec`, so it is a natural, dependency-free content type. gzip/brotli at
  the proxy covers the rest.
- **Vault streaming** uses HTTP range requests / chunked transfer (§8.3), with
  the §3.4 caveat that only a DEK-holding server can range-stream *plaintext*.

### 7.3 Auth: admin-provisioned local accounts, not WebID-OIDC

WebID-OIDC exists to solve **cross-provider single-sign-on in a public
multi-provider ecosystem.** A self-hosted home server has no such ecosystem —
its users are the operator and people the operator explicitly provisions.
Recommended:

- **Admin-provisioned local accounts** (Matrix/Nextcloud model): the operator
  creates accounts / issues credentials. Registration policy is the operator's
  choice; open registration is off by default.
- **Per-device bearer tokens** (Syncthing-flavoured): a device pairs once,
  receives a long-lived token, and presents it as `Authorization: Bearer …`. A
  token maps to exactly one tenant; the router uses it to select the worker
  (§6.2). Tokens are revocable per device.
- **Network identity as a perimeter, not the only gate:** if reached over
  Tailscale, the mesh's device identity is a strong first factor, but the server
  must still enforce tenant scoping itself (defence in depth — never trust the
  network alone to keep tenant A out of tenant B).
- **OIDC optional** for operators who already run an IdP (Authelia, Keycloak) —
  a supported add-on, not the baseline.
- Keep Solid's **philosophy** (the user owns their data store; the server is
  custodian, not owner) as a design value; drop its identity protocol.

> **Inherited limitation to note:** `kmdb_cli`'s `local/config.json` named-remotes
> mechanism (`remote_config.dart`) — where a server would be registered as a sync
> target — currently stores remote credentials as **plaintext JSON**. A server
> credential would inherit that; hardening it (OS keyring) is a prerequisite if a
> long-lived server token is stored there.

---

## 8. API Surface Sketch

The thin client needs three capability groups. Concrete shapes (illustrative,
not final):

### 8.1 Search (the core offload)

```
POST /v1/db/{tenant}/collections/{name}/search
  body:  { "query": "...", "mode": "hybrid|lexical|semantic",
           "fields": ["title","body"], "limit": 20, "offset": 0 }
  reply: { "hits": [ { "id": "...", "score": 0.83, "snippet": "...",
                       "doc": { ... } }, ... ] }        # CBOR or JSON

POST /v1/db/{tenant}/collections/{name}/searchVault
  body:  { "query": "...", "mode": "hybrid", "limit": 10 }
  reply: { "hits": [ { "id": "...", "chunk": { "index": 3, "total": 12,
                       "snippet": "...", "fieldPath": "attachment" },
                       "score": 0.79 }, ... ] }
```

This maps directly onto `KmdbCollection.search()` (§20) and the vault_search
proposal's `searchVault()`. The server runs the embedding model and vector scan;
the client just renders hits.

### 8.2 Document CRUD passthrough

```
GET    /v1/db/{tenant}/collections/{name}/docs/{id}
PUT    /v1/db/{tenant}/collections/{name}/docs/{id}     # body: doc
DELETE /v1/db/{tenant}/collections/{name}/docs/{id}
POST   /v1/db/{tenant}/collections/{name}/query          # Filter DSL → results
```

Reactivity (`watch()`, §14) over the network needs a push channel — **SSE or
WebSocket** streaming write-events for a namespace, debounced server-side. Worth
prototyping but flagged as an open question (§10) since it changes the server
from request/response to stateful-connection.

### 8.3 Vault blob streaming

```
GET /v1/db/{tenant}/vault/{sha256}          # Range: supported
    → 200/206 with blob bytes (server decrypts if DEK-held; §3.4)
HEAD /v1/db/{tenant}/vault/{sha256}          # manifest metadata (size, mimeType)
PUT  /v1/db/{tenant}/vault                   # upload → returns sha256
```

Hydrate-on-demand: a `GET` for a blob the server holds only as a stub triggers a
server-side hydrate from its own sync backend before streaming. Range-streaming
plaintext requires the DEK (§3.4); a zero-knowledge relay can only return the
opaque whole ciphertext blob.

---

## 9. Deployment and Packaging

- **Single binary:** `dart compile exe` produces a self-contained server
  executable; the `betto_onnxrt` native-assets hook bundles the ONNX runtime
  (build must run from inside the package dir per the native-asset-hooks note).
  This is the friendliest artifact for a Pi/VPS operator.
- **Docker image:** the natural distribution and, for multi-tenant, the
  isolation unit (§6.2). One base image; the supervisor plus per-tenant worker
  containers. Immich's multi-container split (API vs ML) is the reference layout.
- **Model asset:** the embedding model (~130 MB for `multilingual-e5-small`, per
  the vault_search multilingual work) is downloaded once via
  `betto_inferencing`'s `ModelDownloader` and can be **memory-mapped read-only
  and shared across tenant workers** to keep per-tenant RAM down.
- **Resource footprint to characterise (open question, §10):** idle per-tenant
  cost (a warm `KmdbDatabase` + caches), active cost (ONNX session + vector scan
  working set), and how many tenants a 4 GB Pi realistically holds with the
  Hotel-Model idle teardown (§6.2). These need measurement, not a guess.
- **Database backend:** unlike Synapse (which outgrows SQLite fast), each tenant
  is an independent embedded KMDB LSM — there is no shared relational DB to
  become a bottleneck, which suits the "many small tenants" shape well.

---

## 10. Open Questions

These are genuine architectural forks that materially change the design and need
the project owner's decision before this becomes a plan. Where a default is
reasonable, it is stated.

1. **DEK-in-server trust posture for multi-tenant hosting (the central
   decision).** Single-user Option 1 (trusted box) is defensible. For
   multi-tenant, is it acceptable that the operator is trusted with every
   tenant's plaintext (all DEKs resident on the box)? Options: (a) accept it,
   document it loudly, rely on process/container isolation (§6) to contain
   *technical* breaches while accepting the operator is trusted; (b) restrict
   multi-tenant to Model A (zero-knowledge relay, no server-side search); (c)
   support both postures per-tenant. *Suggested default: (c) — search offload is
   opt-in per tenant and clearly labelled as "server can read this data."*

2. **How does the server obtain each DEK?** Operator-supplied at start
   (env/keyring), client-supplied-on-connect and cached for the session, or
   only-for-unencrypted-databases? Each has a different UX and threat profile.
   This is unspecified and needs a decision before §5/§8 can be planned.

3. **Primary integration mode.** This proposal recommends **Model C (query API)
   as primary** because it is the only shape that satisfies the motivating use
   case (§4.4), with Model A as an optional zero-knowledge companion. Confirm
   this, or redirect if the priority is actually self-hosted *sync/backup*
   (Model A) rather than search offload.

4. **Tenant isolation boundary.** This proposal resolves **against isolates** and
   recommends **process- or container-per-tenant** (§6). Confirm the appetite for
   the operational weight of container-per-tenant, or accept process-per-tenant
   as the v1 boundary with containers as a hardening follow-up.

5. **Network reactivity.** Do thin clients need live `watch()`/reactive queries
   over the network (SSE/WebSocket, §8.2), or is request/response search+CRUD
   enough for v1? Live reactivity turns the server stateful and is a meaningful
   scope increase.

6. **Should the server be authoritative or a replica?** Is the server the
   *primary* store (thin clients are pure front-ends holding no local data), or a
   *replica* peer (clients keep a local KMDB and use the server only for the
   heavy search)? This changes offline behaviour, conflict handling, and how much
   of §12 sync the client still runs.

7. **Vault streaming scope.** Is whole-blob transfer (matching the current
   `Uint8List` hydrate API) acceptable for v1, or is true HTTP range-streaming
   required? The latter is net-new vault work and does not compose with
   encryption for a DEK-less relay (§3.4).

8. **Resource envelope / target hardware.** What is the low-end target (Pi 4 /
   2 GB? a small VPS?) and expected tenant count? This sets whether the
   Hotel-Model teardown and shared-model-mapping (§9) are must-haves or nice-to-
   haves, and bounds the whole design.

9. **Auth baseline.** Confirm **admin-provisioned local accounts + per-device
   bearer tokens** (§7.3) as the v1 baseline, with OIDC as an optional add-on and
   WebID-OIDC dropped. Also decide whether network identity (Tailscale) may serve
   as a first factor.

10. **Transport.** Confirm **plain HTTP/1.1-2 + CBOR/JSON, exposure-agnostic**
    (§7.2) rather than a mandated HTTP/3 or gRPC stack.

---

## 11. Future Work

- **Federation between KMDB servers** (Matrix-style) — households or communities
  whose servers act as sync points for each other.
- **Keyword-only zero-knowledge search tier** (searchable symmetric encryption /
  blind indexing, §5.3) if a search-without-trust capability is ever wanted,
  accepting exact-match-only limits.
- **Web semantic search parity** — the server is the near-term answer for web
  clients; a future WASM embedding path (vault_search §9) could complement it.
- **Deterministic vault nonces** (encryption proposal §12) so a server can dedup
  ciphertext blobs across tenants/devices without holding the DEK.
- **Horizontal scale-out** — stateless routers over a shared sync folder, if a
  single box is ever outgrown (explicitly not a v1 concern).

---

## 12. References

- [§12 — Sync Protocol](../spec/12_sync.md)
- [§19 — Platform](../spec/19_platform.md)
- [§20 — Text Search Overview](../spec/20_text_search.md)
- [§22 — Semantic Search](../spec/22_semantic_search.md)
- [§23 — Hybrid Search](../spec/23_hybrid_search.md)
- [§24 — Vault](../spec/24_vault.md)
- [§29 — Google Drive Adapter](../spec/29_google_drive_adapter.md) /
  [§30 — iCloud Adapter](../spec/30_icloud_adapter.md) — `SyncStorageAdapter`
  reference implementations
- [§31 — Encryption](../spec/31_encryption.md)
- [Encryption Proposal](encryption.md)
- [Vault Search Proposal](vault_search.md)
- [Solid (decentralized web project)][solid]
- [Community Solid Server][css]
- [Cloudflare Workers security model][cf]
- [Nextcloud multi-instance deployment][nc]
- [Immich architecture][immich]
- [Matrix / Synapse federation][synapse]
- [Tailscale — self-hosting without open ports][ts]

[solid]: https://en.wikipedia.org/wiki/Solid_(web_decentralization_project)
[css]: https://communitysolidserver.github.io/CommunitySolidServer/
[cf]: https://developers.cloudflare.com/workers/reference/security-model/
[nc]: https://deepwiki.com/nextcloud/all-in-one/2.5-multiple-instance-deployment
[immich]: https://docs.immich.app/administration/user-management/
[synapse]: https://github.com/matrix-org/synapse/blob/develop/docs/federate.md
[ts]: https://tailscale.com/blog/last-reverse-proxy-you-need
