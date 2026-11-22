import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/visual_tokens.dart';
import '../../core/outcome.dart';
import '../../domain/repository/account_session.dart';
import '../../sync/health/sync_health.dart';

/// The Google connection of this device: its state, sign-out, and switching
/// to another account.
///
/// Sign-out keeps every task and unsent change on the device. Switching
/// accounts removes the local copy, so it names what would be lost and asks
/// first. Neither changes anything stored in Google Tasks.
final class AccountPage extends StatefulWidget {
  const AccountPage({
    required this.health,
    required this.onHealthAction,
    this.session,
    this.accountBackupBuilder,
    super.key,
  });

  final Stream<SyncHealth> health;

  /// Runs the connect or sign-in action the current health offers.
  final Future<void> Function(SyncHealthAction action) onHealthAction;

  /// Absent until a Google account has been connected.
  final AccountSession? session;

  /// Offered before switching accounts, when backups are available.
  final WidgetBuilder? accountBackupBuilder;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

final class _AccountPageState extends State<AccountPage> {
  StreamSubscription<SyncHealth>? _subscription;
  SyncHealth? _health;
  var _busy = false;
  String? _notice;
  var _noticeIsError = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.health.listen((health) {
      if (mounted) setState(() => _health = health);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  bool get _signedOut {
    final health = _health;
    return health != null &&
        (health.reauthorizationRequired ||
            (health.outcome == SyncHealthOutcome.inactive &&
                health.inactiveReason == SyncInactiveReason.noAuthorization));
  }

  Future<void> _run(
    Future<Outcome<void>> Function() operation, {
    required String success,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    final Outcome<void> outcome;
    try {
      outcome = await operation();
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _notice = 'The action failed unexpectedly. Nothing was changed.';
          _noticeIsError = true;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (outcome) {
        case Success<void>():
          _notice = success;
          _noticeIsError = false;
        case Failed<void>(:final failure):
          _notice = '${failure.impact} ${failure.safeSummary}';
          _noticeIsError = true;
      }
    });
  }

  Future<void> _signOut() async {
    final session = widget.session;
    if (session == null) return;
    final unsent = _health?.counts.total ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('account-sign-out-confirm'),
        title: const Text('Sign out of Google Tasks?'),
        content: Text(
          'Synchronization stops until you sign in again. Your tasks stay on '
          'this device'
          '${unsent > 0 ? ', including ${_changes(unsent)} not yet sent to '
                    'Google' : ''}'
          '. Signing in again with the same account resumes where you left '
          'off.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('account-sign-out-accept'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(
      session.signOut,
      success:
          'Signed out. Your tasks are still on this device; sign in to '
          'synchronize again.',
    );
  }

  Future<void> _switchAccount() async {
    final session = widget.session;
    if (session == null) return;
    final unsent = _health?.counts.total ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('account-switch-confirm'),
        title: const Text('Switch Google account?'),
        content: Text(
          'This signs out and removes this device\'s copy of the current '
          'account so another account can connect. Tasks stored in Google '
          'Tasks are not deleted.'
          '${unsent > 0 ? '\n\n${_changes(unsent)} made on this device '
                    '${unsent == 1 ? 'has' : 'have'} not been sent to '
                    'Google and will be lost. Export an account backup '
                    'first to keep '
                    '${unsent == 1 ? 'it' : 'them'}.' : ''}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('account-switch-accept'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove and switch'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final navigator = Navigator.of(context);
    await _run(() async {
      final outcome = await session.switchAccount();
      // The application reopens at first connection; this page belongs to
      // the account that no longer exists here.
      if (outcome is Success<void> && navigator.mounted) {
        navigator.popUntil((route) => route.isFirst);
      }
      return outcome;
    }, success: 'The local copy was removed. Connect another Google account.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final health = _health;
    final session = widget.session;
    final connected = session != null && !_signedOut;
    final authorizationAction = health?.reauthorizationRequired == true
        ? SyncHealthAction.reauthorize
        : health?.action;
    final unsent = health?.counts.total ?? 0;
    final (statusIcon, statusTitle, statusDetail) = session == null
        ? (
            Icons.cloud_off_outlined,
            'Not connected',
            'Connect a Google account to synchronize tasks.',
          )
        : _signedOut
        ? (
            Icons.logout,
            'Signed out',
            'Your tasks are on this device. Sign in to synchronize again.',
          )
        : (
            Icons.verified_user_outlined,
            'Connected to Google Tasks',
            unsent > 0
                ? '${_changes(unsent)} not yet sent to Google.'
                : 'Every change on this device has been sent to Google.',
          );
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: LayoutBuilder(
        builder: (context, constraints) => Center(
          child: SizedBox(
            width: constraints.maxWidth.clamp(0, 760).toDouble(),
            child: ListView(
              key: const Key('account-scroll'),
              padding: EdgeInsets.all(theme.axiotaskTokens.horizontalInset),
              children: <Widget>[
                Text('Google account', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                ListTile(
                  key: const Key('account-status'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(statusIcon),
                  title: Text(statusTitle),
                  subtitle: Text(statusDetail),
                ),
                Text(
                  'Axiotask talks only to Google Tasks. Access: Google Tasks '
                  '— read and write.',
                  style: theme.textTheme.bodyMedium,
                ),
                if (_notice case final notice?) ...<Widget>[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      notice,
                      key: const Key('account-notice'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _noticeIsError
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: <Widget>[
                    if (!connected &&
                        (authorizationAction == SyncHealthAction.connect ||
                            authorizationAction ==
                                SyncHealthAction.reauthorize))
                      FilledButton.icon(
                        key: const Key('account-sign-in'),
                        onPressed: _busy
                            ? null
                            : () => unawaited(
                                widget.onHealthAction(authorizationAction!),
                              ),
                        icon: const Icon(Icons.login),
                        label: Text(
                          session == null ? 'Connect Google Tasks' : 'Sign in',
                        ),
                      ),
                    if (connected)
                      FilledButton.tonalIcon(
                        key: const Key('account-sign-out'),
                        onPressed: _busy ? null : _signOut,
                        icon: const Icon(Icons.logout),
                        label: const Text('Sign out'),
                      ),
                    if (session != null)
                      OutlinedButton.icon(
                        key: const Key('account-switch'),
                        onPressed: _busy ? null : _switchAccount,
                        icon: const Icon(Icons.switch_account_outlined),
                        label: const Text('Switch account…'),
                      ),
                  ],
                ),
                if (_busy) ...<Widget>[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(key: Key('account-busy')),
                ],
                if (widget.accountBackupBuilder case final builder?
                    when session != null) ...<Widget>[
                  const SizedBox(height: 20),
                  ListTile(
                    key: const Key('account-open-backup'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.save_alt_outlined),
                    title: const Text('Account backup'),
                    subtitle: const Text(
                      'Save everything to a file before switching accounts.',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context)
                        .push<void>(MaterialPageRoute<void>(builder: builder)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _changes(int count) => count == 1 ? '1 change' : '$count changes';
