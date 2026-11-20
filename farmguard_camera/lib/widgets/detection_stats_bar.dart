import 'package:material_ui/material_ui.dart';

import '../services/detection_stats.dart';

/// Compact status bar shown below the live detection preview.
///
/// Displays the running model, the number of people detected in the latest
/// frame, the smoothed inference FPS and the smoothed per-frame processing
/// time in milliseconds.
class DetectionStatsBar extends StatelessWidget {
  const DetectionStatsBar({
    super.key,
    required this.snapshot,
    required this.modelLabel,
  });

  final DetectionSnapshot snapshot;
  final String modelLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statsStyle = theme.textTheme.labelLarge;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.memory,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(modelLabel, style: statsStyle),
              ],
            ),
            _stat(
              theme,
              Icons.person,
              'People: ${snapshot.personCount}',
              statsStyle,
            ),
            _stat(
              theme,
              Icons.speed,
              '${snapshot.fps.toStringAsFixed(1)} FPS',
              statsStyle,
            ),
            _stat(
              theme,
              Icons.timer_outlined,
              '${snapshot.inferenceMs.toStringAsFixed(1)} ms',
              statsStyle,
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(
    ThemeData theme,
    IconData icon,
    String label,
    TextStyle? style,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(label, style: style),
      ],
    );
  }
}
