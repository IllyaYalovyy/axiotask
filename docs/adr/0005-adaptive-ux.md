# ADR 0005: Shared product concepts with adaptive platform layouts

- Status: Accepted
- Date: 2026-08-09

## Problem

A single Flutter codebase must feel native on a wide GNOME desktop and a narrow
touch device. Reusing one literal layout would either waste desktop capability
or produce a cramped mobile UI.

## Alternatives considered

1. One responsive widget tree with conditional visibility throughout. Maximum
   reuse, but platform interaction states become tangled.
2. Completely separate applications/views. Native freedom, with duplicated
   presentation logic and drift.
3. Shared domain, ViewModels, visual tokens, and feature components; distinct
   adaptive shells and layout compositions selected by available capabilities.

## Decision

Choose option 3. Desktop can use navigation/list/detail panes, hover, context
menus, drag, and keyboard. Android uses full-screen routes, reachable touch
actions, gestures with visible alternatives, safe areas, lifecycle, and
predictive back. Shared ViewModels are used when presentation needs match; a
platform-specific ViewModel is allowed when interaction state genuinely differs.

Sync health vocabulary and accessibility semantics are shared contracts.
Screenshots/goldens cover named desktop and phone states.

## Rationale

Sharing product state and behavior prevents platform drift, but desktop and
mobile have materially different space, input, navigation, and lifecycle needs.
Separate compositions preserve native interaction quality without duplicating
domain policy or synchronization semantics.

## Consequences

- Some view widgets are intentionally duplicated compositions, not conditional
  branches inside one giant screen.
- Product policy remains shared and testable outside widgets.
- Breakpoints and input capability matter more than platform-name checks.
- Visual completion requires inspection on both supported form factors.
