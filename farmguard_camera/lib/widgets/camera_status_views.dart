import 'package:material_ui/material_ui.dart';

/// Stateless views for each non-live phase of the camera monitoring flow.
///
/// Each view receives its actions as callbacks so the screen keeps all
/// camera state to itself.

/// Shown when monitoring is stopped: brand placeholder card.
class IdlePlaceholderView extends StatelessWidget {
  const IdlePlaceholderView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videocam_off_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'Camera on standby',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Press Start Monitoring to begin surveillance.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown while the model downloads and the detection view initializes.
class CameraLoadingView extends StatelessWidget {
  const CameraLoadingView({super.key, this.progressLabel});

  /// Optional progress text, e.g. "Downloading model… 42%".
  final String? progressLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'Starting camera…',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (progressLabel != null) ...[
          const SizedBox(height: 8),
          Text(
            progressLabel!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// Shown when the user denied camera permission (retry can re-prompt).
class PermissionDeniedView extends StatelessWidget {
  const PermissionDeniedView({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatusCard(
      icon: Icons.no_photography_outlined,
      title: 'Camera permission denied',
      message:
          'FarmGuard needs camera access to monitor your farm. '
          'Grant permission and try again.',
      actions: [
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try Again'),
        ),
      ],
      theme: theme,
    );
  }
}

/// Shown when permission appears permanently denied: user must enable it
/// in the Android system settings.
class PermissionPermanentlyDeniedView extends StatelessWidget {
  const PermissionPermanentlyDeniedView({
    super.key,
    required this.onOpenSettings,
    required this.onRetry,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatusCard(
      icon: Icons.gpp_bad_outlined,
      title: 'Camera access is turned off',
      message:
          'The camera permission was denied repeatedly. Enable Camera for '
          'FarmGuard Camera in Android Settings to continue monitoring.',
      actions: [
        FilledButton.icon(
          onPressed: onOpenSettings,
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Open Settings'),
        ),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try Again'),
        ),
      ],
      theme: theme,
    );
  }
}

/// Shown for any non-permission failure (hardware, missing camera, etc.).
class CameraErrorView extends StatelessWidget {
  const CameraErrorView({
    super.key,
    required this.detail,
    required this.onRetry,
  });

  final String? detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatusCard(
      icon: Icons.error_outline,
      title: 'Camera error',
      message: detail ?? 'Something went wrong while starting the camera.',
      actions: [
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try Again'),
        ),
      ],
      theme: theme,
    );
  }
}

/// Shared card layout for the status views above.
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.title,
    required this.message,
    required this.actions,
    required this.theme,
  });

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              children: actions,
            ),
          ],
        ),
      ),
    );
  }
}
