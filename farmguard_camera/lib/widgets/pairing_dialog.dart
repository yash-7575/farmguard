import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';
import '../services/device_registration.dart';

/// Dialog that pairs this device with the FarmGuard backend: the farmer
/// enters the 6-digit code from the dashboard, optionally adjusts the
/// camera name and adds a location.
///
/// The redeem call is injected as [onRedeem] so tests fake it; the dialog
/// shows the server's error message inline on failure and pops with the
/// resulting registration on success.
class PairingDialog extends StatefulWidget {
  const PairingDialog({
    super.key,
    required this.onRedeem,
    this.suggestedName = 'Farm Camera',
  });

  /// Redeems the entered code. Throws on failure ([PairingException]
  /// carries the server's own message). Resolves to the stored
  /// registration on success.
  final Future<CameraRegistration> Function(
    String code,
    String cameraName,
    String? location,
  ) onRedeem;

  /// Prefilled camera-name suggestion.
  final String suggestedName;

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  late final TextEditingController _codeController = TextEditingController();
  late final TextEditingController _nameController =
      TextEditingController(text: widget.suggestedName);
  late final TextEditingController _locationController =
      TextEditingController();

  bool _submitting = false;
  String? _errorText;

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _codeController.text.trim();
    final name = _nameController.text.trim();
    final location = _locationController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _errorText = 'Enter the 6-digit pairing code.');
      return;
    }
    if (name.isEmpty || name.length > 100) {
      setState(() => _errorText = 'Camera name must be 1–100 characters.');
      return;
    }
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    try {
      final registration =
          await widget.onRedeem(code, name, location.isEmpty ? null : location);
      if (mounted) {
        Navigator.of(context).pop(registration);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message =
          error is PairingException ? error.message : 'Pairing failed.';
      setState(() {
        _submitting = false;
        _errorText =
            message.isEmpty ? 'Pairing failed. Check the code and try again.' : message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Pair camera'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter the 6-digit code shown on the FarmGuard dashboard to '
            'link this phone as a farm camera.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _codeController,
            decoration: const InputDecoration(
              labelText: '6-digit code',
              counterText: '',
            ),
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            enabled: !_submitting,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Camera name'),
            enabled: !_submitting,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _locationController,
            decoration:
                const InputDecoration(labelText: 'Location (optional)'),
            enabled: !_submitting,
          ),
          if (_errorText != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorText!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(_submitting ? 'Pairing…' : 'Pair'),
        ),
      ],
    );
  }
}
