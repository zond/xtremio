import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/tv_text_entry.dart';
import '../../widgets/tv_text_field.dart';

/// Settings → Account, over `ctx.profile.auth`.
///
/// Signed out it is the sign-in / create-account form: `Authenticate` with
/// `AuthRequest::Login` or `::Register` (the latter with the GDPR consent
/// the API demands, `from: xtremio`). The engine does not serialize its
/// "authenticating" status, so the pending spinner is local state cleared
/// by `UserAuthenticated` or the `Error` whose source is that event, whose
/// `error.message` is shown inline. Signed in it shows the account, "Sync
/// now" (`SyncLibraryWithAPI`, `PullAddonsFromAPI`, `PullNotifications`)
/// and "Log out"; banners when `profile.addonsLocked` is set (the addon
/// collection could not be fetched after login) and when the library
/// fetch failed (`UserLibraryMissing{true}`, delivered wrapped in an
/// `Error` event; cleared by the plain `UserLibraryMissing{false}` a sync
/// emits). Only event names, `source.event`, `error.message` and the
/// `library_missing` flag are read: the args of these events carry the
/// password and the auth key.
class AccountSection extends StatefulWidget {
  const AccountSection({super.key, required this.ctx});

  /// The `ctx` field, as kept by the screen's `CoreFieldNotifier`.
  final ValueListenable<Map<String, dynamic>?> ctx;

  /// The `gdpr_consent.from` a registration carries.
  static const String consentFrom = 'xtremio';

  static const String libraryNote =
      "Signing in replaces the library on this device with your account's.";

  static const Key emailFieldKey = ValueKey('account-email');
  static const Key passwordFieldKey = ValueKey('account-password');
  static const Key confirmPasswordFieldKey = ValueKey(
    'account-confirm-password',
  );
  static const Key tosCheckboxKey = ValueKey('account-tos');
  static const Key privacyCheckboxKey = ValueKey('account-privacy');
  static const Key marketingCheckboxKey = ValueKey('account-marketing');
  static const Key submitButtonKey = ValueKey('account-submit');
  static const Key addonsLockedBannerKey = ValueKey('account-addons-locked');
  static const Key libraryMissingBannerKey = ValueKey(
    'account-library-missing',
  );

  /// The `source.event` of an `Error` event, when it has one.
  static String? errorSourceOf(RuntimeCoreEvent event) {
    final source = _sourceOf(event);
    return source?['event'] as String?;
  }

  /// The `error.message` of an `Error` event, when it has one.
  static String? errorMessageOf(RuntimeCoreEvent event) {
    final args = event.args;
    if (args is! Map<String, dynamic>) return null;
    final error = args['error'];
    final message = error is Map<String, dynamic> ? error['message'] : null;
    return message is String && message.isNotEmpty ? message : null;
  }

  /// The `library_missing` flag of a `UserLibraryMissing` event, whether
  /// it arrived plainly (`false` after a sync, `true` in the engine's unit
  /// tests only) or as the source of the `Error` the login path wraps it
  /// in; null for any other event.
  static bool? libraryMissingOf(RuntimeCoreEvent event) {
    final Map<String, dynamic>? args;
    switch (event.name) {
      case 'UserLibraryMissing':
        final eventArgs = event.args;
        args = eventArgs is Map<String, dynamic> ? eventArgs : null;
      case 'Error' when errorSourceOf(event) == 'UserLibraryMissing':
        final sourceArgs = _sourceOf(event)?['args'];
        args = sourceArgs is Map<String, dynamic> ? sourceArgs : null;
      default:
        return null;
    }
    return args?['library_missing'] as bool? ?? true;
  }

  static Map<String, dynamic>? _sourceOf(RuntimeCoreEvent event) {
    if (event.name != 'Error') return null;
    final args = event.args;
    if (args is! Map<String, dynamic>) return null;
    final source = args['source'];
    return source is Map<String, dynamic> ? source : null;
  }

  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  CoreClient? _client;
  StreamSubscription<CoreEvent>? _events;

  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirmPassword = TextEditingController();

  bool _registering = false;
  bool _tos = false;
  bool _privacy = false;
  bool _marketing = false;

  /// An `Authenticate` is in flight.
  bool _pending = false;

  /// The message under the form: a validation failure or the API's answer.
  String? _error;

  /// The account's library could not be fetched at login.
  bool _libraryMissing = false;

  /// A `SyncLibraryWithAPI` is in flight (cleared by its plan or error).
  bool _syncing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _events?.cancel();
      _client = client;
      _events = client.events.listen(_onEvent);
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  void _onEvent(CoreEvent event) {
    if (event is! RuntimeCoreEvent || !mounted) return;
    final libraryMissing = AccountSection.libraryMissingOf(event);
    if (libraryMissing != null) {
      setState(() => _libraryMissing = libraryMissing);
      return;
    }
    switch (event.name) {
      case 'UserAuthenticated':
        setState(() {
          _pending = false;
          _error = null;
          _password.clear();
          _confirmPassword.clear();
        });
      case 'UserLoggedOut':
        setState(() {
          _libraryMissing = false;
          _syncing = false;
          _error = null;
        });
      case 'LibrarySyncWithAPIPlanned':
        setState(() => _syncing = false);
      case 'Error':
        switch (AccountSection.errorSourceOf(event)) {
          case 'UserAuthenticated':
            setState(() {
              _pending = false;
              _error =
                  AccountSection.errorMessageOf(event) ??
                  (_registering
                      ? 'The account could not be created'
                      : 'Could not sign in');
            });
          case 'LibrarySyncWithAPIPlanned':
            setState(() => _syncing = false);
        }
    }
  }

  void _toggleMode() => setState(() {
    _registering = !_registering;
    _error = null;
  });

  /// Why the form cannot be submitted as it stands, or null.
  String? _validate() {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      return 'Enter a valid email address';
    }
    if (_password.text.isEmpty) return 'Enter a password';
    if (!_registering) return null;
    if (_confirmPassword.text != _password.text) {
      return 'The passwords do not match';
    }
    if (!_tos || !_privacy) {
      return 'Accept the Terms of Service and the Privacy Policy to '
          'create an account';
    }
    return null;
  }

  void _submit() {
    if (_pending) return;
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _pending = true;
      _error = null;
    });
    final email = _email.text.trim();
    final password = _password.text;
    _client?.dispatch(
      _registering
          ? CoreActions.register(
              email: email,
              password: password,
              consent: GdprConsent(
                tos: _tos,
                privacy: _privacy,
                marketing: _marketing,
                from: AccountSection.consentFrom,
              ),
            )
          : CoreActions.login(email: email, password: password),
    );
  }

  void _sync() {
    if (_syncing) return;
    setState(() => _syncing = true);
    final client = _client;
    if (client == null) return;
    client.dispatch(CoreActions.syncLibraryWithAPI());
    client.dispatch(CoreActions.pullAddonsFromAPI());
    client.dispatch(CoreActions.pullNotifications());
  }

  void _logout() => _client?.dispatch(CoreActions.logout());

  void _retryAddons() => _client?.dispatch(CoreActions.pullAddonsFromAPI());

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: widget.ctx,
      builder: (context, ctx, _) {
        if (ctx == null) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final profile = ProfileState.fromCtx(ctx);
        final user = profile.user;
        return user == null
            ? _buildSignedOut(context)
            : _buildSignedIn(context, profile, user);
      },
    );
  }

  Widget _buildSignedOut(BuildContext context) {
    final theme = Theme.of(context);
    final error = _error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TvTextField(
            key: AccountSection.emailFieldKey,
            controller: _email,
            enabled: !_pending,
            kind: TvTextKind.email,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          const SizedBox(height: 8),
          TvTextField(
            key: AccountSection.passwordFieldKey,
            controller: _password,
            enabled: !_pending,
            kind: TvTextKind.password,
            autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: _registering ? null : (_) => _submit(),
          ),
          if (_registering) ...[
            const SizedBox(height: 8),
            TvTextField(
              key: AccountSection.confirmPasswordFieldKey,
              controller: _confirmPassword,
              enabled: !_pending,
              kind: TvTextKind.password,
              decoration: const InputDecoration(labelText: 'Confirm password'),
              onSubmitted: (_) => _submit(),
            ),
            CheckboxListTile(
              key: AccountSection.tosCheckboxKey,
              value: _tos,
              enabled: !_pending,
              onChanged: (value) => setState(() => _tos = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text('I agree to the Terms of Service'),
            ),
            CheckboxListTile(
              key: AccountSection.privacyCheckboxKey,
              value: _privacy,
              enabled: !_pending,
              onChanged: (value) => setState(() => _privacy = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text('I agree to the Privacy Policy'),
            ),
            CheckboxListTile(
              key: AccountSection.marketingCheckboxKey,
              value: _marketing,
              enabled: !_pending,
              onChanged: (value) => setState(() => _marketing = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text('Send me news about Stremio (optional)'),
            ),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _pending
                    ? const Center(
                        child: SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : FilledButton(
                        key: AccountSection.submitButtonKey,
                        onPressed: _submit,
                        child: Text(
                          _registering ? 'Create account' : 'Sign in',
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: _pending ? null : _toggleMode,
                child: Text(
                  _registering
                      ? 'I already have an account'
                      : 'Create an account',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            AccountSection.libraryNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSignedIn(
    BuildContext context,
    ProfileState profile,
    UserInfo user,
  ) {
    final avatar = user.avatar;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: CircleAvatar(
            foregroundImage: avatar == null ? null : NetworkImage(avatar),
            onForegroundImageError: avatar == null ? null : (_, _) {},
            child: const Icon(Icons.person_outline),
          ),
          title: Text(user.email),
          subtitle: const Text('Signed in'),
        ),
        if (profile.addonsLocked)
          _Banner(
            key: AccountSection.addonsLockedBannerKey,
            icon: Icons.lock_outline,
            message:
                'Your addon collection could not be fetched, so the '
                'official addons are in use and addon changes are locked '
                'until it is.',
            actionLabel: 'Retry',
            onAction: _retryAddons,
          ),
        if (_libraryMissing)
          _Banner(
            key: AccountSection.libraryMissingBannerKey,
            icon: Icons.cloud_off_outlined,
            message:
                "Your account's library could not be fetched; this device "
                'shows an empty library until a sync succeeds.',
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              _syncing
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : FilledButton.tonalIcon(
                      onPressed: _sync,
                      icon: const Icon(Icons.sync),
                      label: const Text('Sync now'),
                    ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _logout,
                icon: const Icon(Icons.logout),
                label: const Text('Log out'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                children: [
                  Icon(icon, color: scheme.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
              if (actionLabel != null)
                TextButton(onPressed: onAction, child: Text(actionLabel!))
              else
                const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
