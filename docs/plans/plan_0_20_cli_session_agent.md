# CLI session agent — unlock once, reuse across commands

**Status**: Draft — **Deferred to v0.2.0** (decision 2026-08-26; filed to the
v0.2.0 roadmap 2026-09-06). See [docs/roadmap/0_20.md](../roadmap/0_20.md).

**PR link**: _(none yet)_

> **Deferred out of `0.1.0` (2026-08-26; recorded on the
> [v0.2.0 roadmap](../roadmap/0_20.md) 2026-09-06).** This is a CLI ergonomics
> improvement, not a correctness item: it does **not** close SC-1 (WI-5 already
> did, [PR #75](https://github.com/bettongia/kmdb/pull/75)), and it introduces
> the single highest-risk new subsystem in the track (a new place a DEK lives).
> Shipping it under release time-pressure is exactly the wrong trade. `0.1.0`
> ships without a CLI DEK session cache — every encrypted-DB command re-runs
> Argon2id, which is acceptable for the REPL. This plan stays Draft and is
> picked up in `0.2.0`, when it can go through the full
> reviewer → implement → QA pipeline unhurried.
>
> This file was renamed from `plan_0_10_01_cli_session_agent.md` on 2026-09-06
> to match its target release.

> **Provenance.** Split out of `plan_0_10_01_unlock_policy.md` (WI-5) on
> 2026-08-11 on the reviewer's recommendation: the CLI session agent is a
> substantial new subsystem, is the highest-risk component (a new place a DEK
> lives), and — unlike the rest of WI-5 — **does not close SC-1**. It addresses
> the separate CLI ergonomics finding (proposal §2.3 / §4.4). Sequenced **after**
> WI-5, since it depends on WI-5's wrapped-DEK model and the core `SecretStore`
> seam. Originated in the [0.10.01 hardening track](../roadmap/0_10_01.md)
> (WI-5 family); now carried on the [v0.2.0 roadmap](../roadmap/0_20.md).

## Problem statement

`kmdb_cli` has **no DEK cache** (proposal §2.3). Every command that opens an
encrypted database therefore runs full Argon2id (~200 ms) — tolerable in the
REPL, painful for scripting a sequence of commands. WI-5 deliberately removes
the raw-DEK `DekCache` (it is the SC-1 bug class), so the CLI needs a *different*
mechanism to avoid re-deriving the KDF per command — one that never returns a
DEK unauthenticated.

## Goals

Unlock once; subsequent commands reuse a short-lived session until it expires,
without weakening the SC-1 guarantee and without persisting a DEK to disk.

## Settled design decisions (from proposal §4.4 + WI-5 resolved §9)

- **DEK lives in agent process memory**, never on disk. A cache file would reuse
  the permission-hardened directory but is a materially weaker posture.
- **Lifetime = idle timeout *and* an absolute cap** (the `sudo` / `op signin`
  model), whichever fires first.
- **`kmdb … lock` ends the session immediately**; the agent **never outlives the
  login session**.
- **Single database first** — namespace multiple databases later via the core
  `dbScopedSecretKey` (promoted to core in WI-5).
- **Ships inside `kmdb_cli`** (not a separate package).
- Owner-only access, reusing the credential-store permission posture on POSIX.

## Open questions (investigation — must close before `Investigated`)

These are the reasons this was split out; none is answered yet.

- [ ] **IPC transport.** Unix domain socket on POSIX (owner-only, reusing the
      `DirectorySecretStore` permission model). **Windows has no Unix socket** —
      named pipe with an explicit ACL? Windows is a supported CLI/CI target, so
      this needs a real design, not "POSIX chmod".
- [ ] **Socket/pipe location & discovery.** `$XDG_RUNTIME_DIR` on Linux;
      macOS and Windows have no direct equivalent — where does the endpoint live,
      and how does a `kmdb` command discover and (auto?)spawn the agent?
- [ ] **Wire protocol.** Request/response framing; which operations the agent
      exposes (unlock, get-DEK-for-db, lock, status); how the DEK is handed to a
      requesting command process without landing on disk.
- [ ] **"Never outlives the login session" enforcement, per OS.** Concretely how
      — session-scoped runtime dir teardown, parent-process death detection,
      logout hooks? Differs per platform.
- [ ] **Interaction with WI-5's `KEKSource`/`ReauthPolicy`.** The agent caches an
      *authenticated* DEK; confirm the re-auth policy still applies (the absolute
      cap should not exceed the WI-5 interval, and `alwaysRequirePassphrase`
      should disable agent caching).
- [ ] **Authorisation.** How the agent authenticates a requesting process as the
      same user (peer credentials over the socket / pipe).

## Implementation plan

_To be written once the open questions are resolved (the agent's subsystem shape
determines the phases). Will follow the same commit-per-stage discipline as WI-5._

## Summary

_To be completed when the work is done._
