import 'package:material_ui/material_ui.dart';

import '../services/api/exceptions.dart';
import '../services/app_services.dart';
import '../services/messaging/messaging_gateway.dart';
import '../services/messaging/push_session.dart';
import '../widgets/async_states.dart';
import 'login_screen.dart';
import 'main_shell.dart';

/// Startup auth gate.
///
/// On boot it reads the stored token: none (or rejected by the backend) →
/// the login screen; valid → the main shell. A transient failure on first
/// launch shows a retry-able error card — the farmer may simply be offline.
///
/// After a successful login/register (or when the shell reports an expired
/// session) this widget swaps between [LoginScreen] and [MainShell], so the
/// whole app always lives under one MaterialApp/theme.
class AuthGate extends StatefulWidget {
  final AppServices services;

  const AuthGate({super.key, required this.services});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

enum _Phase { bootstrap, bootstrapError, login, session }

class _AuthGateState extends State<AuthGate> {
  _Phase _phase = _Phase.bootstrap;
  String _farmerName = 'Farmer';
  String _farmerEmail = '';
  PushSession? _pushSession;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() => _phase = _Phase.bootstrap);
    final String? token = await widget.services.tokenStore.readToken();
    if (token == null) {
      if (mounted) setState(() => _phase = _Phase.login);
      return;
    }
    try {
      final result = await widget.services.auth.me();
      if (!mounted) return;
      setState(() {
        _farmerName = result.farmerName;
        _farmerEmail = result.email;
        _phase = _Phase.session;
      });
      _startMessaging();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = error.isUnauthorized
            ? _Phase.login
            : _Phase.bootstrapError;
      });
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.bootstrapError);
    }
  }

  /// Login / register succeeded → enter the shell with the fresh session.
  void _onAuthenticated(String farmerName, String farmerEmail) {
    setState(() {
      _farmerName = farmerName;
      _farmerEmail = farmerEmail;
      _phase = _Phase.session;
    });
    _startMessaging();
  }

  /// Push notifications start with the session: Firebase init + permission
  /// prompt + backend device registration + token-refresh re-registration.
  /// Best-effort — a declined permission or any non-401 failure leaves the
  /// app fully functional (push silently skipped).
  void _startMessaging() {
    final MessagingGateway? gateway = widget.services.messaging;
    if (gateway == null) return; // test wiring without a gateway
    final PushSession session = PushSession(
      gateway: gateway,
      notifications: widget.services.notifications,
    );
    _pushSession = session;
    session.start().then(
      (_) {},
      onError: (Object error) {
        // registerDevice hit a dead session (401) → same expiry path as
        // the data calls; everything else is swallowed by the session.
        if (error is ApiException && error.isUnauthorized) {
          _onSessionExpired();
        }
      },
    );
  }

  /// The shell hit a 401 → clear the dead token and return to login.
  Future<void> _onSessionExpired() async {
    await _teardownPush();
    await widget.services.auth.logout();
    if (mounted) setState(() => _phase = _Phase.login);
  }

  /// Settings → Log out: unregister the device token with the backend
  /// first (best-effort — logout must never fail because unregister did),
  /// then clear the session.
  Future<void> _logout() async {
    await _teardownPush();
    await widget.services.auth.logout();
    if (mounted) setState(() => _phase = _Phase.login);
  }

  /// Stops the push session (unregister + refresh subscription teardown).
  /// Never throws.
  Future<void> _teardownPush() async {
    final PushSession? session = _pushSession;
    _pushSession = null;
    await session?.stop();
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _Phase.bootstrap:
        return Scaffold(
          body: const SafeArea(
            child: LoadingView(message: 'Checking your session…'),
          ),
        );
      case _Phase.bootstrapError:
        return Scaffold(
          body: SafeArea(
            child: ErrorCard(
              title: "Couldn't reach FarmGuard",
              message:
                  'We could not verify your session. Check your connection '
                  'and try again.',
              onRetry: _bootstrap,
            ),
          ),
        );
      case _Phase.login:
        return LoginScreen(
          auth: widget.services.auth,
          onAuthenticated: _onAuthenticated,
        );
      case _Phase.session:
        return MainShell(
          services: widget.services,
          farmerName: _farmerName,
          farmerEmail: _farmerEmail,
          onSessionExpired: _onSessionExpired,
          onLogout: _logout,
        );
    }
  }
}
