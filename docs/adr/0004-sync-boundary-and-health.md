# ADR 0004: UI-independent sync boundary and truthful health

- Status: Accepted
- Date: 2026-08-09

## Problem

The previous client could show a healthy indicator while authorization had
expired and no synchronization occurred. It also allowed an open/editing UI
item to influence create synchronization. A Google Tasks client cannot ask the
user to trust stale data or a status light unrelated to remote success.

## Alternatives considered

1. Let each feature call the Google service and show its own loading/error state.
   Responsive locally, but creates concurrent runs, inconsistent health, and no
   global recovery model.
2. Put sync in a ViewModel/application singleton that reads current UI state.
   Easy wiring, but impossible to test or reason about independently.
3. Persist all acknowledged intent, run one headless engine behind a coalescing
   coordinator, and project one typed health state from auth/run/pending history.
4. Rely on connectivity and token presence for a simple green/red indicator.
   Neither proves that Google accepted or returned current state.

## Decision

Choose option 3. Repository transactions create durable, coalesced desired
remote state for each changed resource. A serialized coordinator reacts to
startup, resume, connectivity hints, committed mutations, foreground cadence,
and explicit retry. It coalesces bursts and invokes a Flutter-independent
engine.

`SyncHealth` is derived below the UI from the sync-enabled flag, authorization,
current phase, last attempt, last verified successful run, failures since
success, pending count, uncertain operations, and connectivity hints. It exposes
four top-level outcomes: Inactive, Good, Failed, and Pending. Inactive carries a
mandatory `syncStopped` or `noAuthorization` reason. Good requires a complete
remote sync inside a bounded freshness window and no newer failure, queued run,
pending work, or uncertainty. Failed carries a concrete reason such as
`noConnection`, `remoteFailure`, `applicationFailure`, or `stale`; it includes
request/run timeout and expired freshness when verification is not active.
Active/queued verification and unconfirmed work are Pending. No authorization
is emitted only by the authorization adapter for absent credentials/scope or a
terminal Google authorization rejection; ordinary network failure remains
Failed.

Stopping sync is a durable scheduler control, not sign-out: it prevents new
runs, safely cancels an active run, and preserves credentials, cache, and queued
desired state. Editing remains fully available and continues coalescing durable
desired state while synchronization is stopped. Resume schedules immediate
catch-up. A run may publish remote pages
incrementally, but health cannot become Good or advance last verified success
until the complete run succeeds.

At ADR acceptance, exact synchronization phases, retries, conflicts,
timeout/freshness durations, and operation semantics were deliberately deferred
to Stage 4 without weakening these health invariants.

Stage 4 accepted refinement (2026-08-11): `SYNC_SPEC.md` now supplies those
details. Foreground cadence is five minutes; local mutation, startup, resume,
connectivity-restored, and explicit Retry triggers remain immediate under their
specific rules. Retry backoff waiting is Failed so a detected failure remains
immediately visible; only an executing retry request is Pending. Good means the
latest forced or scheduled required run completed successfully and is still
inside its freshness window. The UI reports “Synced” with the exact completion
time; it does not claim that Google's non-atomic pagination produced an atomic
snapshot.

## Rationale

Only durable intent and completed Google interaction can support a truthful
health claim. A serialized headless coordinator makes those facts independent
of transient UI state, while the four-outcome projection gives both platforms
one testable definition of inactive, pending, failed, and good synchronization.

## Consequences

- Desktop and Android display the same truth using platform-appropriate UI.
- A connectivity event schedules verification but can never turn health green.
- The UI can disappear or process can die without losing acknowledged intent.
- Scheduler behavior is deterministic with an injected clock.
- The architecture preserves explicit uncertain outcomes and failure reasons
  without inventing a generic manual-intervention bucket or making manual
  conflict copies the default strategy.
