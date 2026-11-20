import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../widgets/camera_card.dart';

/// Camera management: list of cameras with online/offline status, last
/// connection time and monitoring toggle. Cameras come from the backend
/// via the shell; online state is never fabricated.
///
/// A "Pair a camera" card sits at the top of the list ([onPairCamera]) —
/// it opens the pairing-code dialog in the shell.
class CamerasScreen extends StatelessWidget {
  final List<FarmCamera> cameras;

  /// Optional slim banner shown under the title when a refresh failed but
  /// cached cameras are still displayed.
  final Widget? topBanner;

  /// Opens the pairing-code flow. `null` hides the card.
  final VoidCallback? onPairCamera;

  /// Opens the remove-camera confirmation flow. `null` hides the per-card
  /// remove action.
  final Future<void> Function(FarmCamera camera)? onRemoveCamera;

  /// Cameras with a delete request in flight — their remove action is
  /// disabled until the request settles.
  final Set<String> removingCameraIds;

  const CamerasScreen({
    super.key,
    required this.cameras,
    this.topBanner,
    this.onPairCamera,
    this.onRemoveCamera,
    this.removingCameraIds = const <String>{},
  });

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int online = cameras.where((c) => c.isOnline).length;
    final int offline = cameras.length - online;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text('Cameras', style: textTheme.headlineMedium),
                ),
                if (onPairCamera != null)
                  FilledButton.tonal(
                    onPressed: onPairCamera,
                    child: const Text('Pair a camera'),
                  ),
              ],
            ),
          ),
          if (topBanner != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: topBanner!,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Row(
              children: <Widget>[
                _SummaryDot(
                  color: scheme.primary,
                  label: '$online online',
                ),
                const SizedBox(width: 16),
                _SummaryDot(
                  color: scheme.error,
                  label: '$offline offline',
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              itemCount: cameras.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (BuildContext context, int index) {
                final FarmCamera camera = cameras[index];
                return CameraCard(
                  key: ValueKey<String>(camera.id),
                  camera: camera,
                  onRemove: onRemoveCamera,
                  isRemoving: removingCameraIds.contains(camera.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryDot extends StatelessWidget {
  final Color color;
  final String label;

  const _SummaryDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}
