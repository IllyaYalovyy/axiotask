# Dependency decisions

Evaluated against Flutter 3.44 / Dart 3.12 in August 2026. Versions are resolved
and locked when the first implementation slice is scaffolded; a package is not
added merely because it appears in this design.

## Planned production dependencies

| Dependency | Problem it earns its place by solving | Decision and constraints |
|---|---|---|
| `provider` | Explicit composition/lifetime and narrow widget subscriptions without a service locator | Use for dependency injection and ViewModel exposure only. Flutter's architecture guide recommends it for DI. Do not move domain state into provider objects. |
| `drift`, `drift_flutter`, `sqlite3` | Typed transactional SQLite, reactive queries, schema verification, native Android/Linux support, and testable connection injection | Accepted. Drift code generation is justified by persistence/sync correctness. Use sqlite3 3.x native assets; do not add obsolete `sqlite3_flutter_libs`. |
| `http` | Small composable HTTP client used by a strict Google Tasks REST adapter | Accepted. Prefer the Dart-team package over `dio`; retries/auth/error parsing remain explicit policy outside the transport. |
| `google_sign_in` | Maintained Flutter/Android Google authentication and authorization API | Android only, provisional on the mandatory physical-device capability gate. Do not write a replacement Google SDK integration if it fails. |
| `oauth2` | Standards-level Authorization Code + PKCE and refresh mechanics | Linux only. Used behind a DPoP-aware HTTP client; browser callback, secure persistence, state/nonce validation, and errors remain application responsibilities. |
| `jose` | ES256 JWS/JWK primitives for standards-compliant DPoP proofs | Linux only and provisional on a Google endpoint capability test. Require 0.3.5+2 or newer; versions before 0.3.5+1 have CVE-2026-34240. Application code constructs only the narrow RFC 9449 proof claims. |
| `flutter_secure_storage` | Linux refresh-token and DPoP-key persistence through GNOME Secret Service/libsecret | Linux only, provisional on a capability test against the exact locked version. Never fall back to plaintext or enable silent destructive reset behavior. Fedora requires `libsecret`/`libsecret-devel` and an active Secret Service. Android authorization remains owned by `google_sign_in`. |
| `connectivity_plus` | Foreground connectivity-change hints on Android and Linux | Accepted only as a trigger. Its own documentation says connectivity does not prove internet access; sync requests remain authoritative. |
| `url_launcher` | System-browser OAuth on Linux, recurrence escape hatch, and safe external links | Accepted, with an application wrapper and fake for tests. Only validated schemes are launched. |
| `path_provider` | Correct per-platform application support and temporary paths | Accepted at the storage composition boundary; tests inject paths/connections. It may arrive through Drift but direct use is declared when APIs are imported directly. |
| `shared_preferences` | Small device-local presentation settings that need no relational integrity | Use only the current `SharedPreferencesAsync` API behind `PreferencesRepository`. Never store sync-critical, account-scoped, relational, or irreplaceable data because the package does not guarantee critical-write durability. |

## Planned development dependencies

- Flutter SDK `flutter_test` and `integration_test`.
- `flutter_lints` plus project-specific stricter analyzer settings.
- `drift_dev` and `build_runner` for database code generation.

Generated Drift code is committed and the local quality gate verifies that
regeneration produces no diff. This makes source-only local builds reproducible
without hiding stale generated code.

Manual fakes are preferred to Mockito/Mocktail. Flutter's built-in golden support
is preferred to a visual framework until a demonstrated gap appears.

## Admitted in S00

The scaffold admits only Flutter SDK 3.44.8, its bundled `flutter_test`, and
`flutter_lints` 6.0.0. The SDK supplies both native runners and widget testing;
`flutter_lints` supplies the Flutter-maintained BSD-licensed baseline that the
project extends with strict analyzer settings. It is maintained by the Flutter
team, has no production/native footprint, and can be removed by replacing the
included lint baseline without changing runtime state. Linux and Android debug
builds and the smoke test pass against the exact committed lock. No third-party
runtime package is admitted by S00.

## Deliberately not selected

| Candidate | Reason |
|---|---|
| Riverpod, Bloc, Redux | Adds a second state framework when immutable ViewModels, streams, and `ChangeNotifier` cover the identified needs. Reconsider only with a concrete failure. |
| `get_it` or another service locator | Hides dependencies and weakens test construction. |
| `freezed`, `built_value`, `json_serializable` | Domain/wire model volume does not yet justify additional generators. Strict explicit mapping is easier to audit. Drift generation remains isolated to persistence. |
| `go_router` | No deep-link or route graph requirement currently earns it. Use Navigator first. |
| `dio` | Interceptors and a larger API do not improve the narrow Tasks REST protocol over `http`. |
| generated `googleapis` Tasks client | Sync requires explicit etags, headers, retry classification, raw status handling, and strict wire validation. A narrow manual adapter is more transparent and smaller. |
| WorkManager/background scheduler | Android product policy is foreground/resume synchronization only. |
| `golden_toolkit` or Patrol | Built-in widget/golden/integration facilities cover the initial plan. Native auth is verified by a focused physical-device harness; add tooling only for a proven gap. |
| SQLCipher initially | Tokens are secured separately; Android sandbox/device encryption and the Fedora user account protect the cache in the stated threat model. SQLCipher adds native/key-recovery failure modes without protecting data while the user session is compromised. Revisit if encrypted cache at rest becomes a product requirement. |
| a generic sync/offline framework | Google Tasks semantics and reliability requirements require an explicit, owned engine and fake. |

## Dependency admission checklist

Before adding or upgrading a meaningful package, record:

1. the concrete problem standard Flutter/Dart APIs do not solve adequately;
2. supported Fedora/Android behavior and minimum SDK impact;
3. publisher, maintenance activity, license, and known critical issues;
4. transitive/native build impact;
5. how it is isolated behind an application boundary and faked in tests;
6. a local compile/smoke result on every affected supported platform;
7. removal or fallback strategy that does not corrupt user state.

Primary references:

- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations)
- [`provider`](https://pub.dev/packages/provider)
- [`drift`](https://pub.dev/packages/drift)
- [`sqlite3` 3.x](https://pub.dev/packages/sqlite3)
- [`http`](https://pub.dev/packages/http)
- [`google_sign_in`](https://pub.dev/packages/google_sign_in)
- [`oauth2`](https://pub.dev/packages/oauth2)
- [`jose`](https://pub.dev/packages/jose)
- [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage)
- [`connectivity_plus`](https://pub.dev/packages/connectivity_plus)
- [`shared_preferences`](https://pub.dev/packages/shared_preferences)
