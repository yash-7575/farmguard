import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../services/api/exceptions.dart';
import '../services/api/farmer_api.dart';

/// Dialog that generates and displays a 6-digit camera pairing code
/// (POST /api/v1/pairing/code): the farmer reads the code into the
/// FarmGuard Camera app on the farm phone to redeem it.
///
/// The code call is injected as [onCreateCode] so tests fake it — the same
/// seam idiom as the camera app's `PairingDialog.onRedeem`. Errors show
/// inline: transient failures get a Retry, 401 pops the dialog and calls
/// [onSessionExpired] (MainShell's logout path). The countdown runs from
/// the backend's `expires_at` against the injectable [now] clock (tests
/// inject a fixed one) and ticks once per second; when it reaches zero the
/// code is replaced by an expired state with a Generate-new-code affordance.
/// The timer is cancelled on dialog close.
class PairingCodeDialog extends StatefulWidget {
  const PairingCodeDialog({
    super.key,
    required this.onCreateCode,
    this.onSessionExpired,
    this.now = _systemNow,
  });

  /// Generates a pairing code. Throws [ApiException] on failure.
  final Future<PairingCodeResult> Function() onCreateCode;

  /// Called on 401 (session expiry) after the dialog has closed — routes
  /// back to login via the shell's existing path.
  final VoidCallback? onSessionExpired;

  /// Injectable clock used for the expiry countdown.
  final DateTime Function() now;

  static DateTime _systemNow() => DateTime.now();

  @override
  State<PairingCodeDialog> createState() => _PairingCodeDialogState();
}

enum _PairingPhase { generating, ready, expired, error }

class _PairingCodeDialogState extends State<PairingCodeDialog> {
  _PairingPhase _phase = _PairingPhase.generating;
  PairingCodeResult? _result;
  ApiException? _error;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() {
      _phase = _PairingPhase.generating;
      _error = null;
    });
    try {
      final PairingCodeResult result = await widget.onCreateCode();
      if (!mounted) return;
      // A code that is already past its expiry (clock skew, test fixture)
      // goes straight to the expired state — no countdown, regenerate only.
      final Duration remaining = result.expiresAt.difference(widget.now());
      setState(() {
        _result = result;
        _phase = remaining <= Duration.zero
            ? _PairingPhase.expired
            : _PairingPhase.ready;
      });
      if (remaining > Duration.zero) _startTicker();
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        // Session expired: close the dialog first, then let the shell
        // clear the session and return to login.
        Navigator.of(context).pop();
        widget.onSessionExpired?.call();
        return;
      }
      setState(() {
        _error = error;
        _phase = _PairingPhase.error;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = const ApiException(
          statusCode: 0,
          code: 'network',
          message: 'Could not reach the backend. Check your connection.',
        );
        _phase = _PairingPhase.error;
      });
    }
  }

  /// Ticks once per second, re-reading the injectable clock. Stopped when
  /// the countdown expires and on dispose (dialog close).
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= Duration.zero) {
        _ticker?.cancel();
        setState(() => _phase = _PairingPhase.expired);
      } else {
        setState(() {}); // re-render the countdown
      }
    });
  }

  Duration get _remaining => _result == null
      ? Duration.zero
      : _result!.expiresAt.difference(widget.now());

  /// Countdown text in mm:ss (codes expire in 5 minutes).
  String get _countdown {
    final Duration remaining = _remaining;
    final String minutes =
        remaining.inMinutes.clamp(0, 99).toString().padLeft(2, '0');
    final String seconds =
        (remaining.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Pair a camera'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          switch (_phase) {
            _PairingPhase.generating => Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Column(
                    children: <Widget>[
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(
                        'Generating pairing code…',
                        style: textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            _PairingPhase.ready => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Center(
                    child: Text(
                      _result!.code,
                      style: textTheme.displaySmall?.copyWith(
                        letterSpacing: 6,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Expires in $_countdown',
                      style: textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Open FarmGuard Camera on the farm phone → Start '
                    'Monitoring → Pair this camera, then enter this code.',
                    style: textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  // Lost the code or want a fresh one — codes are
                  // single-use, so regenerating is always safe.
                  Center(
                    child: TextButton(
                      onPressed: _generate,
                      child: const Text('Generate new code'),
                    ),
                  ),
                ],
              ),
            _PairingPhase.expired => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'This code has expired.',
                    style: textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: FilledButton(
                      onPressed: _generate,
                      child: const Text('Generate new code'),
                    ),
                  ),
                ],
              ),
            _PairingPhase.error => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _error!.message,
                    style:
                        textTheme.bodySmall?.copyWith(color: scheme.error),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: FilledButton(
                      onPressed: _generate,
                      child: const Text('Retry'),
                    ),
                  ),
                ],
              ),
          },
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
