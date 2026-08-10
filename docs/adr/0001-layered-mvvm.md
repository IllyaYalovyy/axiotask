# ADR 0001: Layered MVVM with an explicit domain layer

- Status: Accepted
- Date: 2026-08-09

## Problem

The application needs adaptive Flutter UI, complex reusable task policy, and a
sync engine that can be tested without Flutter. The previous client allowed
domain behavior and transient UI state to leak across boundaries.

## Constraints

- Small, stable interfaces and obvious dependency direction.
- Desktop/mobile presentation can differ without duplicating behavior.
- No architectural boilerplate for hypothetical platforms or features.
- Easy construction with fakes and no global mutable services.

## Alternatives considered

1. Put state and behavior directly in widgets with a few shared services. Small
   initially, but repeats policy and makes headless tests difficult.
2. Adopt Bloc/Riverpod/Redux as the application architecture. These can work,
   but introduce framework-specific state concepts that are not required by the
   known problem.
3. Use Flutter's View/ViewModel + repository/service guidance, add a domain
   layer only for shared complex policy, and use `provider` for composition.
4. Apply a full clean-architecture/use-case layer to every action. Boundaries
   are explicit but trivial operations acquire needless classes and mappings.

## Decision

Choose option 3. Views render immutable ViewModel state. Repositories expose
application state and commands. Services adapt external systems. The domain
layer owns rules shared by UI, persistence, and sync. Dependencies are injected
through constructors and wired with `provider` at the composition root.

`ChangeNotifier` is allowed for ViewModels only. Repository streams and sealed
domain values remain Flutter-independent. A use-case object is added only when
an operation coordinates multiple repositories/policies or needs independent
testing; one class per button is forbidden.

## Rationale

This keeps synchronization and reusable task policy independent of Flutter
without imposing a framework or ceremony on every simple interaction. It also
allows desktop and Android presentation to diverge while retaining explicit,
constructor-injected dependencies and deterministic headless tests.

## Consequences

- Widget tests stay focused on presentation and interaction.
- Desktop and Android views can share ViewModels selectively.
- Domain and sync tests run as ordinary Dart tests.
- Some explicit mapping between wire, persistence, domain, and view state is
  accepted to prevent external formats from contaminating policy.
- A future state-framework change is localized to UI composition/ViewModels.
