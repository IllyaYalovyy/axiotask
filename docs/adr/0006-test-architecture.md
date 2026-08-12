# ADR 0006: Deterministic fakes plus isolated real-system tests

- Status: Accepted
- Date: 2026-08-09

## Problem

Synchronization and platform behavior require more confidence than mocked
happy paths, while normal tests must never access personal tasks, credentials,
or application storage.

## Alternatives considered

1. Mock each collaborator and assert calls. Fast, but brittle and unable to
   demonstrate convergence or real state.
2. Rely heavily on end-to-end tests against Google. Realistic but slow,
   nondeterministic, destructive if misconfigured, and poor at fault injection.
3. Use deterministic stateful fakes and real SQLite for the broad matrix, narrow
   adapter contract tests, plus explicit opt-in real API/device probes.
4. Record/replay production HTTP traffic. Convenient fixtures, but likely to
   capture personal data/tokens and age poorly.

## Decision

Choose option 3. Time, randomness, connectivity, lifecycle, storage paths,
authorization, secure storage, URL launching, and Google services are injected.
The fake models real remote state and controlled failure/interleaving behavior.
A shared contract suite ties it to the HTTP adapter and recorded real-API
assumptions.

Real Google tests require dedicated ignored credentials/account, unique
disposable data, explicit invocation, and cleanup. Before any Tasks enumeration
or mutation, the harness must compare the authenticated Google subject with an
explicit ignored expected-subject value and fail closed on mismatch; an operator
confirmation alone is insufficient. Android authentication needs a
physical-device gate. UI uses unit/ViewModel/widget/integration tests, curated
goldens, and actual screenshot inspection with synthetic data.

Process-death evidence runs the production persistence path in a killable child
process against a real temporary SQLite database, terminates it at named durable
boundaries, and verifies recovery from a separate process. Throwing an exception
inside one test process does not prove crash safety.

Diagnostics have separate verified compositions. Release tests assert that
task-content and credential canaries never reach the production-safe sink.
Debug-development tests assert that task-content and detailed API/storage
context are retained locally while credential canaries remain redacted, and
that the sensitive in-app viewer is easy to reach. Release composition cannot
construct or enable that sensitive sink or viewer at runtime.

## Rationale

Stateful fakes and real SQLite provide broad deterministic evidence for
convergence, interruption, and failure handling. Narrow opt-in Google and device
tests then validate facts that local doubles cannot prove, while strict
isolation prevents normal verification from touching personal data or accounts.

## Consequences

- The normal local gate is fast, deterministic, and safe offline.
- Fakes require meaningful maintenance and are tested rather than trusted.
- A small number of manual/opt-in platform gates remain necessary evidence.
- No source-grep tests, arbitrary sleeps, personal-data recordings, or implicit
  real-account fallback are accepted.
- Sensitive development diagnostics use only synthetic or dedicated test-account
  data, remain local/ignored, and are never uploaded automatically.
