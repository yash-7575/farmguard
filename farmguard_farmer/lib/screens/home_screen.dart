import 'package:material_ui/material_ui.dart';

import '../data/mock_data.dart';
import '../models/models.dart';
import '../utils/formatters.dart';
import '../widgets/detection_tile.dart';
import '../widgets/event_image.dart';
import '../widgets/fg_card.dart';
import '../widgets/section_header.dart';
import '../widgets/stat_card.dart';

/// Home dashboard: greeting, farm monitoring status, today's metrics,
/// recent detections and quick access to the full history.
///
/// Data is injected by the shell: [events] holds live events (newest first)
/// followed by the retained demo records; [cameras] backs the tile lookups;
/// [connectedCameras]/[totalCameras] come from live camera data only and are
/// `null` while unknown, in which case the stat shows "—" and the status
/// card reports that the status is unavailable (never fabricated).
class HomeScreen extends StatelessWidget {
  final List<DetectionEvent> events;

  /// Cameras available for tile lookups (live + demo).
  final List<FarmCamera> cameras;

  final int? connectedCameras;
  final int? totalCameras;

  /// Optional slim banner shown above the metrics when a refresh failed.
  final Widget? topBanner;

  final VoidCallback onSeeAllHistory;
  final void Function(DetectionEvent event) onOpenEvent;

  /// Byte loader for backend frames (`api:` image paths).
  final EventImageLoader? imageLoader;

  const HomeScreen({
    super.key,
    required this.events,
    required this.cameras,
    required this.connectedCameras,
    required this.totalCameras,
    required this.onSeeAllHistory,
    required this.onOpenEvent,
    this.topBanner,
    this.imageLoader,
  });

  FarmCamera? _cameraById(String id) {
    for (final FarmCamera camera in cameras) {
      if (camera.id == id) return camera;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int todayDetections = MockData.todayCount(events);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Header(
              greeting: greeting(),
              hasOfflineCamera: connectedCameras != null &&
                  totalCameras != null &&
                  connectedCameras! < totalCameras!,
            ),
            if (topBanner != null) ...<Widget>[
              const SizedBox(height: 12),
              topBanner!,
            ],
            const SizedBox(height: 20),
            _MonitoringStatusCard(
              monitoringCameras: connectedCameras,
              totalCameras: totalCameras,
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: StatCard(
                    icon: Icons.person_search,
                    label: 'Detections today',
                    value: '$todayDetections',
                    iconColor: scheme.onPrimaryContainer,
                    iconContainer: scheme.primaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: StatCard(
                    icon: Icons.videocam,
                    label: 'Connected cameras',
                    value: connectedCameras == null || totalCameras == null
                        ? '—'
                        : '$connectedCameras / $totalCameras',
                    iconColor: scheme.onSecondaryContainer,
                    iconContainer: scheme.secondaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SectionHeader(
              title: 'Recent detections',
              actionLabel: 'View all',
              onAction: onSeeAllHistory,
            ),
            for (final DetectionEvent event in events.take(3))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DetectionTile(
                  event: event,
                  camera: _cameraById(event.cameraId),
                  imageLoader: imageLoader,
                  onTap: () => onOpenEvent(event),
                ),
              ),
            const SizedBox(height: 8),
            _HistoryQuickAccess(onTap: onSeeAllHistory),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String greeting;
  final bool hasOfflineCamera;

  const _Header({required this.greeting, required this.hasOfflineCamera});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '$greeting,',
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text('Farmer', style: textTheme.headlineMedium),
            ],
          ),
        ),
        Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.person, color: scheme.onPrimaryContainer),
            ),
            if (hasOfflineCamera)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: scheme.error,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.surface, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _MonitoringStatusCard extends StatelessWidget {
  final int? monitoringCameras;
  final int? totalCameras;

  const _MonitoringStatusCard({
    required this.monitoringCameras,
    required this.totalCameras,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool unknown = monitoringCameras == null || totalCameras == null;
    final bool allGood = !unknown && monitoringCameras == totalCameras;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
            child: Icon(
              unknown
                  ? Icons.help_outline
                  : allGood
                      ? Icons.shield
                      : Icons.shield_outlined,
              color: scheme.onPrimary,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  unknown
                      ? 'Status unavailable'
                      : allGood
                          ? 'Farm is protected'
                          : 'Attention needed',
                  style: textTheme.titleMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  unknown
                      ? 'Connect to see the live camera status'
                      : '$monitoringCameras of $totalCameras cameras monitoring for people',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
          const _PulseDot(),
        ],
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect the OS "remove animations" accessibility setting.
    final bool disabled = MediaQuery.disableAnimationsOf(context);
    if (disabled) {
      return Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
        ),
      );
    }
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _HistoryQuickAccess extends StatelessWidget {
  final VoidCallback onTap;

  const _HistoryQuickAccess({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return FgCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.history,
              size: 19,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Detection history',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}
