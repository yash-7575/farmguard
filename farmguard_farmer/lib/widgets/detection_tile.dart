import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../utils/formatters.dart';
import 'event_image.dart';
import 'fg_card.dart';
import 'status_chip.dart';

/// List tile for a detection event (History screen + Home recent list).
///
/// Shows a LIVE/DEMO source chip next to the New badge: demo records are
/// always labelled, a LIVE chip only appears for backend events.
class DetectionTile extends StatelessWidget {
  final DetectionEvent event;
  final FarmCamera? camera;
  final VoidCallback onTap;

  /// Byte loader for backend frames (`api:` paths). Asset demo frames
  /// render through `Image.asset` unchanged.
  final EventImageLoader? imageLoader;

  const DetectionTile({
    super.key,
    required this.event,
    required this.camera,
    required this.onTap,
    this.imageLoader,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return FgCard(
      padding: const EdgeInsets.all(10),
      onTap: onTap,
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 68,
              height: 68,
              child: EventImage(
                event: event,
                loader: imageLoader,
                semanticLabel:
                    'Captured frame from ${camera?.name ?? 'camera'}',
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Person detected',
                        style: textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    event.isDemo
                        ? const StatusChip.demo()
                        : const StatusChip.live(),
                    if (event.isNew) ...<Widget>[
                      const SizedBox(width: 6),
                      const StatusChip.newBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${camera?.name ?? 'Unknown camera'} · ${formatEventTime(event.timestamp)}',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                Row(
                  children: <Widget>[
                    Icon(Icons.insights, size: 13, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text(
                      '${(event.confidence * 100).toStringAsFixed(0)}% confidence',
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}
