import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../data/event_codec.dart';
import '../../models/models.dart';
import '../theme/app_colors.dart';

/// Loader signature injected from the shell: [EventRepository.getImage].
typedef EventImageLoader = Future<Uint8List?> Function(DetectionEvent event);

/// The captured frame of a detection event.
///
/// Two sources:
/// - asset-backed demo events (`assets/…` paths) → `Image.asset`, exactly as
///   the app has always rendered them;
/// - backend events (`api:` marker) → bytes fetched through the injected
///   [EventImageLoader] (which fronts the repository's LRU cache) and
///   rendered as `Image.memory`, with muted placeholder / "no image" states.
///
/// The `api:` branch never crashes: fetch errors (including 404 frame-
/// unavailable) degrade to the placeholder. When no loader is injected, an
/// `api:` event degrades to the placeholder too.
class EventImage extends StatelessWidget {
  final DetectionEvent event;
  final EventImageLoader? loader;
  final BoxFit fit;

  /// Semantic label passed to the underlying image.
  final String? semanticLabel;

  /// Whether the error state shows a "No image" caption (detail view) or
  /// just the muted icon (tile thumbnails).
  final bool showLabel;

  /// Icon size used by the placeholder / error states.
  final double iconSize;

  const EventImage({
    super.key,
    required this.event,
    this.loader,
    this.fit = BoxFit.cover,
    this.semanticLabel,
    this.showLabel = false,
    this.iconSize = 24,
  });

  bool get _isApiImage => event.imagePath.startsWith(kApiImagePathPrefix);

  @override
  Widget build(BuildContext context) {
    if (!_isApiImage || loader == null) {
      return Image.asset(
        event.imagePath,
        fit: fit,
        semanticLabel: semanticLabel,
      );
    }
    return FutureBuilder<Uint8List?>(
      future: loader!(event),
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _muted(
            child: SizedBox(
              width: iconSize,
              height: iconSize,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final Uint8List? bytes = snapshot.data;
        if (snapshot.hasError || bytes == null) {
          return _muted(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.image_not_supported_outlined,
                  size: iconSize,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                if (showLabel) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    'No image',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
          );
        }
        return Image.memory(
          bytes,
          fit: fit,
          semanticLabel: semanticLabel,
        );
      },
    );
  }

  /// Muted well behind placeholder / error states (the same surface used
  /// for thumbnails and avatar wells elsewhere in the app).
  Widget _muted({required Widget child}) {
    return Container(
      color: AppColors.surfaceMuted,
      alignment: Alignment.center,
      child: child,
    );
  }
}
