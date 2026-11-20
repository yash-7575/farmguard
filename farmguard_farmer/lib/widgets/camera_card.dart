import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../utils/formatters.dart';
import 'fg_card.dart';
import 'status_chip.dart';

/// Camera management card: identity, online status and monitoring toggle.
///
/// The monitoring switch is local UI state (Phase 1 mock). When [onRemove] is
/// supplied the card also offers a compact "Remove Camera" action; the owner
/// (the cameras screen) is responsible for the confirmation dialog and the
/// backend call.
class CameraCard extends StatefulWidget {
  final FarmCamera camera;

  /// Opens the remove-camera confirmation flow. `null` hides the action.
  final Future<void> Function(FarmCamera camera)? onRemove;

  /// While true the remove action is disabled (a delete request is in
  /// flight for this camera).
  final bool isRemoving;

  const CameraCard({
    super.key,
    required this.camera,
    this.onRemove,
    this.isRemoving = false,
  });

  @override
  State<CameraCard> createState() => _CameraCardState();
}

class _CameraCardState extends State<CameraCard> {
  late bool _monitoring = widget.camera.isMonitoring;

  /// Short, copy-friendly id shown on the card (backend ids can be long
  /// UUIDs; the first 8 characters are enough to identify a camera).
  String get _shortId {
    final String id = widget.camera.id;
    return id.length > 8 ? id.substring(0, 8) : id;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final FarmCamera camera = widget.camera;
    final TextStyle? secondaryStyle = textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return FgCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: camera.isOnline
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.videocam,
                  size: 21,
                  color: camera.isOnline
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(camera.name, style: textTheme.titleMedium),
                    const SizedBox(height: 2),
                    // Location keeps its own Text widget so its exact string
                    // stays findable; the short id sits on its own muted line
                    // so neither of them has to truncate.
                    Text(
                      camera.location,
                      style: secondaryStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'ID: $_shortId',
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              camera.isOnline
                  ? const StatusChip.online('Online')
                  : const StatusChip.offline('Offline'),
            ],
          ),
          const SizedBox(height: 8),
          Divider(color: scheme.outlineVariant),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Icon(
                Icons.schedule,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  camera.lastConnected == null
                      ? 'Never connected'
                      : 'Last connected ${timeAgo(camera.lastConnected!)}',
                  style: secondaryStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Semantics(
                label: 'Monitoring toggle for ${camera.name}',
                child: SizedBox(
                  height: 32,
                  child: Switch(
                    value: _monitoring,
                    onChanged: (bool value) =>
                        setState(() => _monitoring = value),
                  ),
                ),
              ),
              if (widget.onRemove != null) ...<Widget>[
                const SizedBox(width: 2),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    onPressed: widget.isRemoving
                        ? null
                        : () => widget.onRemove!(camera),
                    icon: const Icon(Icons.link_off, size: 18),
                    tooltip: 'Remove Camera',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                    style: IconButton.styleFrom(
                      foregroundColor: scheme.error,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
