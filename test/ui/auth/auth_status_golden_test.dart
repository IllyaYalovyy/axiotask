// Goldens for the standalone auth/status widgets (T6.2).
//
// The footer priority states and the Account-tab states are pinned as pixel
// snapshots under the REAL app light theme, so a regression in the priority
// chrome (which button, which color dot, which phrase) is a byte diff a
// reviewer must explain — never a silent rewrite (TESTING.md §"Golden
// discipline").
//
// Determinism: no scenario carries a `lastSynced`, so nothing reads the clock
// (the "Synced N ago" label is exercised by the widget test under withClock).
// No button is focused, so there is no cursor/ripple timer. Each snapshot is a
// pure function of the widget tree.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/ui/auth/account_section.dart';
import 'package:axiotask/src/ui/auth/auth_sync_footer.dart';
import 'package:axiotask/src/ui/auth/auth_sync_status.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';

/// A footer at sidebar width under the real light theme.
Widget _footer(AuthSyncStatus status) => Theme(
  data: buildLightTheme(),
  child: Material(
    color: buildLightTheme().colorScheme.surface,
    child: SizedBox(
      width: 220,
      child: AuthSyncFooter(
        status: status,
        onSignIn: () {},
        onSignOut: () {},
        onSync: () {},
        onOpenProperties: () {},
      ),
    ),
  ),
);

/// An Account section under the real light theme. `pendingPushes` stays 0 and
/// no reset notice is set, so every scenario is a pure function of the auth
/// state — the destructive "Switch account" block (#215) renders in all three,
/// which is the point: its gating is part of the pinned chrome.
Widget _account({
  required bool isAuthenticated,
  required bool needsReauth,
  List<String> scopes = const ['https://www.googleapis.com/auth/tasks'],
}) => Theme(
  data: buildLightTheme(),
  child: Material(
    color: buildLightTheme().colorScheme.surface,
    child: SizedBox(
      width: 420,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: AccountSection(
          isAuthenticated: isAuthenticated,
          needsReauth: needsReauth,
          scopes: scopes,
          onSignIn: () {},
          onSignOut: () {},
          onResetLocalData: () {},
        ),
      ),
    ),
  ),
);

void main() {
  goldenTest(
    'auth footer — priority states',
    fileName: 'auth_footer_states',
    builder: () => GoldenTestGroup(
      columns: 2,
      children: [
        GoldenTestScenario(
          name: 'signed out',
          child: _footer(
            const AuthSyncStatus(isAuthenticated: false, needsReauth: false),
          ),
        ),
        GoldenTestScenario(
          name: 'signed in (ready)',
          child: _footer(
            const AuthSyncStatus(isAuthenticated: true, needsReauth: false),
          ),
        ),
        GoldenTestScenario(
          name: 'needs reauth',
          child: _footer(
            const AuthSyncStatus(isAuthenticated: true, needsReauth: true),
          ),
        ),
        GoldenTestScenario(
          name: 'needs attention',
          child: _footer(
            const AuthSyncStatus(
              isAuthenticated: true,
              needsReauth: false,
              needsAttention: true,
            ),
          ),
        ),
        GoldenTestScenario(
          name: 'syncing',
          child: _footer(
            const AuthSyncStatus(
              isAuthenticated: true,
              needsReauth: false,
              activity: SyncActivity.syncing,
            ),
          ),
        ),
        GoldenTestScenario(
          name: 'sync error',
          child: _footer(
            const AuthSyncStatus(
              isAuthenticated: true,
              needsReauth: false,
              hasError: true,
            ),
          ),
        ),
      ],
    ),
  );

  goldenTest(
    'account section — auth states',
    fileName: 'account_states',
    builder: () => GoldenTestGroup(
      columns: 1,
      children: [
        GoldenTestScenario(
          name: 'signed in',
          child: _account(isAuthenticated: true, needsReauth: false),
        ),
        GoldenTestScenario(
          name: 'needs reauth',
          child: _account(isAuthenticated: true, needsReauth: true),
        ),
        GoldenTestScenario(
          name: 'signed out',
          child: _account(
            isAuthenticated: false,
            needsReauth: false,
            scopes: const [],
          ),
        ),
      ],
    ),
  );
}
