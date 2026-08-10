# Functional parity matrix

This matrix prevents accidental feature loss while allowing deliberate redesign.
The Rust/Tauri application on `main` is behavioral evidence, not architectural
precedent. Statuses here are planning dispositions; implementation and
verification columns will be added/updated as vertical slices land.

Legend: **Retain** = parity requirement, **Redesign** = same user need with new
behavior/UX, **Drop** = intentionally unsupported, **Defer** = not in the first
usable milestone, **Investigate** = evidence/product behavior still required.

| Capability | Rust evidence | Flutter disposition | Required verification / note |
|---|---|---|---|
| Google account connection | app auth commands/RFC-001 | Redesign | Platform adapter tests plus Linux and physical Android end-to-end proof |
| Truthful sync health | existing indicator and failure reports | Redesign, highest priority | Every health state in unit/widget/golden/integration tests; token expiry must never remain green |
| Stop/resume synchronization | sync controls | Redesign | Preserve authorization/cache/queue; stop new runs and catch up immediately on resume |
| Google list discovery | task-list commands/sync pull | Retain | Fake, HTTP contract, and opt-in real API |
| Local-only lists | `local_only` list state | Drop | Domain/schema must not represent unsynchronizable lists |
| Create/rename/delete Google lists | list commands | Retain | Delete semantics finalized in Stage 4 |
| List ordering in the client | frontend local preference | Retain | Persist in SQLite and test cross-restart behavior |
| Exclude lists from smart views | frontend local preference | Retain | Persist in SQLite; desktop/mobile settings coverage |
| Create/edit/delete task | task commands | Retain | Transactional local acknowledgement plus eventual remote verification |
| Complete/uncomplete task | task commands | Retain | Parent/subtask behavior specified before implementation |
| Undo delete | undo command | Investigate | Retain only if Google semantics allow a reliable, clearly bounded undo |
| Notes editing | notes command/detail UI | Retain | Long/empty/unicode content and offline behavior |
| Due-date editing/clearing | due commands | Retain | Time-zone/date-only contract tests |
| Today/tomorrow/week/month shortcuts | UI date actions | Retain | Date calculations use injected clock and locale policy |
| Quick add | quick-add UI | Redesign | One/two-interaction capture on desktop and Android |
| Natural-language date preview | quick-add parser | Retain cautiously | Explicit grammar and preview; never silently reinterpret ambiguous text |
| Bulk paste | bulk-add command/UI | Retain | Title/notes parsing, limits, rollback/partial-failure policy |
| Multi-select | UI state | Retain | Keyboard, pointer, touch, and system-back tests |
| Bulk complete/reschedule/move/delete | bulk commands | Retain | Transactional intent and per-item remote outcome |
| Manual top-level ordering | move/reorder commands | Retain | Stage 4 defines Google position semantics and concurrent reorder behavior |
| Move between lists | cross-list move | Retain, redesign sync semantics | No automatic copying of Rust's data-loss policy |
| One level of subtasks | detail UI/domain convention | Retain | Exact product limit; domain rejects deeper local depth and never mutates unexpected deeper API data |
| Add/edit/complete/date/reorder subtask | task detail commands | Retain | Full domain + widget + integration coverage |
| Detach subtask | detach command | Retain | Resulting top-level position and failure behavior specified |
| Parent subtask progress | task row UI | Retain | Shared domain projection, not duplicated in widgets |
| Parent completion cascade | UX decisions | Investigate | Stage 4/product rule must explicitly define Google/local behavior |
| Effective parent due date | frontend policy | Retain | Pure domain policy tests |
| Focus smart view | frontend filter | Retain | Exact window/inclusion policy documented and tested |
| Upcoming smart view | frontend filter | Retain | Exact window/overlap documented and tested |
| Missed smart view | frontend filter | Retain | Boundary/time-zone tests |
| Unscheduled smart view | frontend filter | Retain | Domain query tests |
| All smart view | frontend filter | Retain | Domain query tests |
| Per-view sorting | frontend local preference | Retain | Manual/due/title/created; SQLite-backed preference |
| Show completed | frontend local preference | Retain | Per-view persistence and query behavior |
| Search title and notes | frontend search | Retain | Includes subtask matches with parent context |
| Desktop keyboard shortcuts | desktop UI tests | Retain | Discoverable equivalents and focus-conflict tests |
| Desktop context/hover actions | desktop UI | Redesign | No action available only through hover/right-click |
| Drag reorder | desktop UI | Retain | Pointer and failure/reconciliation coverage |
| Android drawer/navigation | mobile UI | Redesign | Choose after screenshot prototypes; preserve navigation capability |
| Android FAB/fast creation | mobile UI | Retain concept | Touch reachability and keyboard/inset tests |
| Android swipe/long press | mobile UI | Redesign | Alternative accessible controls required |
| Pull to refresh | mobile UI | Retain | Requests immediate foreground sync and displays actual result |
| Android system back | mobile UI tests | Retain | Predictive-back-aware state tests |
| Responsive safe areas | mobile CSS/tests | Retain correctly in Flutter | Real Android screenshot/device checks |
| Theme/light-dark mode | frontend preference | Retain | Device-local `SharedPreferencesAsync` setting; system/default behavior specified |
| Onboarding | frontend UI | Redesign | Focus on connection, sync truth, and first useful workflow |
| Backup/export | JSON commands | Retain | Required user safety feature; explicit account-aware format and privacy warning |
| Restore/import | JSON commands | Retain, redesign safety semantics | Validate completely before mutation; import into the Google-backed operation pipeline without bypassing sync invariants |
| Fresh sync/reset cache | command | Development/recovery only | Safe recovery design must preserve pending acknowledged work |
| Push-disabled/read-only sync | setting | Drop from product | May exist only in isolated development harness if complexity is negligible |
| Multiple isolated instances | `AXIOTASK_PREFIX` | Drop from product | Test isolation is provided through injected paths/app IDs, not a user feature |
| Open in Google Tasks | `webViewLink` action | Retain as recurrence workaround | Label “Manage recurrence in Google Tasks”; test missing/invalid links |
| Open user-authored web links | URL handling | Retain separately | Strict scheme parsing and launch-failure behavior |
| Recurrence editing | unsupported by Tasks API | Unsupported | Never simulate recurrence; route to Google UI |
| Offline cached reading/editing | SQLite + pending operations | Retain | Clearly degraded health plus restart/reconnect convergence |
| Periodic Android background sync | scheduler concept | Drop | Foreground/resume only by product decision |
| Play-Services-free Android mode | mobile auth design | Drop | No dedicated effort |
| Cross-product tasks assigned from Docs/Chat | not part of standalone Tasks UX | Drop | Keep `showAssigned` false; these externally assigned/shared resources are outside Axiotask's task model |
| Telemetry/analytics | absent | Continue absence | Repository/dependency review |

## Evidence maintenance

When implementation begins, each row gains links to its Flutter specification,
tests, implementation, visual evidence where relevant, and final verification.
An intentional behavior change requires an ADR or product note; a blank row is
not permission to omit a capability.
