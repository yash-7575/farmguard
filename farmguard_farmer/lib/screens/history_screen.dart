import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../widgets/detection_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/event_image.dart';

/// Detection history: every event with thumbnail, timestamp, camera,
/// confidence and New/Viewed status, plus a LIVE/DEMO source chip per tile.
/// Live events come first (newest first); retained demo records stay
/// visible below, always labelled.
///
/// Shows a friendly empty state when there are no detections at all, and a
/// "Load more" affordance when the backend reports an older page
/// ([onLoadMore] non-null).
class HistoryScreen extends StatelessWidget {
  final List<DetectionEvent> events;

  /// Cameras available for tile lookups (live + demo).
  final List<FarmCamera> cameras;

  /// Optional slim banner shown under the title when a refresh failed.
  final Widget? topBanner;

  /// Whether an older page exists (backend cursor). When true a "Load
  /// more" button is appended to the list.
  final bool canLoadMore;
  final bool isLoadingMore;
  final VoidCallback? onLoadMore;

  final void Function(DetectionEvent event) onOpenEvent;

  /// Byte loader for backend frames (`api:` image paths).
  final EventImageLoader? imageLoader;

  const HistoryScreen({
    super.key,
    required this.events,
    required this.cameras,
    required this.onOpenEvent,
    this.topBanner,
    this.canLoadMore = false,
    this.isLoadingMore = false,
    this.onLoadMore,
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
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('Detection history', style: textTheme.headlineMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              '${events.length} events · ${events.where((e) => e.isNew).length} new',
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (topBanner != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: topBanner!,
            ),
          Expanded(
            child: events.isEmpty
                ? const EmptyState(
                    icon: Icons.person_search,
                    title: 'No detections yet',
                    message:
                        'When a person is detected by one of your cameras, '
                        'the event will appear here.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    itemCount:
                        events.length + (canLoadMore && onLoadMore != null ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (BuildContext context, int index) {
                      if (index >= events.length) {
                        return _LoadMoreButton(
                          isLoading: isLoadingMore,
                          onTap: onLoadMore,
                        );
                      }
                      final DetectionEvent event = events[index];
                      return DetectionTile(
                        event: event,
                        camera: _cameraById(event.cameraId),
                        imageLoader: imageLoader,
                        onTap: () => onOpenEvent(event),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _LoadMoreButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback? onTap;

  const _LoadMoreButton({required this.isLoading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Center(
      child: FilledButton.tonal(
        onPressed: onTap,
        child: const Text('Load more'),
      ),
    );
  }
}
