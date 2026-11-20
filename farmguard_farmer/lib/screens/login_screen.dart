import 'package:material_ui/material_ui.dart';

import '../data/repositories/auth_repository.dart';
import '../services/api/exceptions.dart';
import '../services/api/farmer_api.dart';
import '../widgets/fg_card.dart';

/// Sign-in / registration screen, in the app's Material 3 emerald design
/// language: warm off-white background, white FgCard form, emerald filled
/// button, muted supporting text.
///
/// Field validation (email shape, password ≥ 8, name 1–100) shows inline
/// under each field. Backend errors map to an inline banner for credential
/// problems (401 / 409); transient failures surface as a snackbar with a
/// retry-friendly message. API failures never crash the screen.
class LoginScreen extends StatefulWidget {
  /// Injected authentication flows (repository persists the token on
  /// success). The app's idiom: constructor injection, fakes in tests.
  final AuthRepository auth;

  /// Called with the signed-in farmer's identity after a successful
  /// login or registration (the token is already persisted by the
  /// repository).
  final void Function(String farmerName, String farmerEmail) onAuthenticated;

  const LoginScreen({
    super.key,
    required this.auth,
    required this.onAuthenticated,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();

  bool _isRegister = false;
  bool _busy = false;
  bool _obscure = true;

  /// Inline banner text for credential errors (401 / 409), `null` when none.
  String? _banner;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final bool valid = _formKey.currentState?.validate() ?? false;
    if (!valid) return;

    setState(() {
      _busy = true;
      _banner = null;
    });

    final String email = _email.text.trim();
    final String password = _password.text;

    try {
      final AuthResult result = _isRegister
          ? await widget.auth.register(_name.text.trim(), email, password)
          : await widget.auth.login(email, password);
      if (!mounted) return;
      widget.onAuthenticated(result.farmerName, result.email);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (error.statusCode == 409) {
        setState(() {
          _banner =
              'An account with this email already exists. Try signing in '
              'instead.';
        });
      } else if (error.statusCode == 401) {
        setState(() {
          _banner = _isRegister
              ? error.message
              : 'Incorrect email or password.';
        });
      } else if (error.isTransient) {
        _showSnackBar(
          "Couldn't reach the server. Check your connection and try again.",
        );
      } else {
        _showSnackBar(error.message);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showSnackBar('Something went wrong. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // ── Brand header ────────────────────────────────────────
                Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.shield,
                      size: 30,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'FarmGuard',
                  textAlign: TextAlign.center,
                  style: textTheme.headlineMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  _isRegister
                      ? 'Create your farm monitoring account'
                      : 'Sign in to watch over your farm',
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                // ── Form card ───────────────────────────────────────────
                FgCard(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (_banner != null) ...<Widget>[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: scheme.errorContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: <Widget>[
                                Icon(
                                  Icons.error_outline,
                                  size: 18,
                                  color: scheme.onErrorContainer,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _banner!,
                                    style: textTheme.bodySmall?.copyWith(
                                      color: scheme.onErrorContainer,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (_isRegister) ...<Widget>[
                          TextFormField(
                            controller: _name,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                            validator: _validateName,
                            textInputAction: TextInputAction.next,
                          ),
                          const SizedBox(height: 14),
                        ],
                        TextFormField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            prefixIcon: Icon(Icons.alternate_email),
                          ),
                          validator: _validateEmail,
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _password,
                          obscureText: _obscure,
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              tooltip:
                                  _obscure ? 'Show password' : 'Hide password',
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                size: 20,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                          validator: _validatePassword,
                          onFieldSubmitted: (_) => _submit(),
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _busy ? null : _submit,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                          child: _busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  _isRegister ? 'Create account' : 'Sign in',
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _isRegister = !_isRegister;
                            _banner = null;
                          }),
                  child: Text(
                    _isRegister
                        ? 'Already have an account? Sign in'
                        : 'New to FarmGuard? Create an account',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Field validators ────────────────────────────────────────────────────

  String? _validateName(String? value) {
    final String trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) return 'Enter your name.';
    if (trimmed.length > 100) return 'Name must be 100 characters or fewer.';
    return null;
  }

  String? _validateEmail(String? value) {
    final String trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) return 'Enter your email.';
    if (!trimmed.contains('@') || trimmed.contains(' ')) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.length < 8) {
      return 'Password must be at least 8 characters.';
    }
    return null;
  }
}
