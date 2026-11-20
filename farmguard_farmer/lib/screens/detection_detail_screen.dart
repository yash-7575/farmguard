import 'package:material_ui/material_ui.dart';

import '../data/repositories/event_repository.dart';
import '../models/models.dart';
import '../services/api/exceptions.dart';
import '../utils/formatters.dart';
import '../widgets/event_image.dart';
import '../widgets/fg_card.dart';
import '../widgets/status_chip.dart';

/// Detection details: full captured frame with bounding-box visualization,
/// timestamp, camera info, confidence and event ID.
///
/// Live (backend) events: the frame is fetched through the injected
/// [eventRepository] (`api:` image path); a fetch failure or missing frame
/// degrades to a muted "no image" placeholder, never a crash. Opening a
/// live event also fires-and-forgets [EventRepository.markViewed] — the
/// local isViewed mutation stays with the caller so the New → Viewed
/// transition still works across tabs.
class DetectionDetailScreen extends StatefulWidget {
  final DetectionEvent event;

  /// Resolved camera for name/location display (live or demo).
  final FarmCamera? camera;

  /// Byte source for backend frames; `null` degrades `api:` frames to the
  /// placeholder. Also the markViewed source for live events.
  final EventRepository? eventRepository;

  /// Called with errors from the fire-and-forget markViewed call (used by
  /// the shell to react to an expired session).
  final void Function(ApiException error)? onViewedError;

  const DetectionDetailScreen({
    super.key,
    required this.event,
    this.camera,
    this.eventRepository,
    this.onViewedError,
  });

  @override
  State<DetectionDetailScreen> createState() => _DetectionDetailScreenState();
}

class _DetectionDetailScreenState extends State<DetectionDetailScreen> {
  @override
  void initState() {
    super.initState();
    final EventRepository? repository = widget.eventRepository;
    if (repository != null && !widget.event.isDemo) {
      // Fire-and-forget: the shell already mutated isViewed locally; this
      // only reports to the backend. Errors are swallowed (an expired
      // session is reported so the shell can re-login).
      repository.markViewed(widget.event.id).then((_) {},
          onError: (Object error) {
        if (error is ApiException) widget.onViewedError?.call(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final FarmCamera? camera = widget.camera;
    final DetectionEvent event = widget.event;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Detection details'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: event.isDemo
                  ? const StatusChip.demo()
                  : const StatusChip.live(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: event.isNew
                  ? const StatusChip.newBadge()
                  : StatusChip(
                      label: 'Viewed',
                      color: scheme.onSurfaceVariant,
                      container: scheme.surfaceContainerHigh,
                    ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: <Widget>[
          // ── Captured frame with bounding boxes ─────────────────────────
          FgCard(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      EventImage(
                        event: event,
                        loader: widget.eventRepository?.getImage,
                        semanticLabel:
                            'Captured frame with ${event.boxes.length} person '
                            'detection',
                        showLabel: true,
                        iconSize: 36,
                      ),
                      _Boxes(event: event),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Person detected', style: textTheme.titleMedium),
                      const SizedBox(height: 3),
                      Text(
                        '${camera?.name ?? 'Unknown camera'} · ${formatEventTime(event.timestamp)}',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ── Event facts ────────────────────────────────────────────────
          FgCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                _FactRow(
                  icon: Icons.schedule,
                  title: 'Time',
                  value: formatEventTime(event.timestamp),
                ),
                Divider(color: scheme.outlineVariant, indent: 56),
                _FactRow(
                  icon: Icons.videocam,
                  title: 'Camera',
                  value: camera == null ? 'Unknown camera' : camera.name,
                ),
                Divider(color: scheme.outlineVariant, indent: 56),
                _FactRow(
                  icon: Icons.place,
                  title: 'Location',
                  value: camera?.location ?? '—',
                ),
                Divider(color: scheme.outlineVariant, indent: 56),
                _ConfidenceRow(confidence: event.confidence),
                Divider(color: scheme.outlineVariant, indent: 56),
                _FactRow(
                  icon: Icons.badge,
                  title: 'Event ID',
                  value: event.id,
                  valueStyle: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Captured automatically when person detection triggered on this camera.',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Boxes extends StatelessWidget {
  final DetectionEvent event;

  const _Boxes({required this.event});

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder re-runs the painter with the actual rendered size; the
    // boxes are stored in normalized coordinates so they stay aligned.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: _BoxPainter(boxes: event.boxes),
        );
      },
    );
  }
}

class _BoxPainter extends CustomPainter {
  final List<DetectionBox> boxes;

  _BoxPainter({required this.boxes});

  static const Color stroke = Color(0xFF34D399);
  static const Color labelBg = Color(0xFF065F46);

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < boxes.length; i++) {
      final DetectionBox box = boxes[i];
      final Rect rect = Rect.fromLTWH(
        box.left * size.width,
        box.top * size.height,
        box.width * size.width,
        box.height * size.height,
      );
      final RRect rrect = RRect.fromRectAndRadius(
        rect,
        const Radius.circular(6),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = stroke,
      );
      if (i == 0) {
        _drawLabel(
          canvas,
          rect.topLeft,
          boxes.length > 1 ? '${boxes.length} persons' : 'Person',
        );
      }
    }
  }

  void _drawLabel(Canvas canvas, Offset at, String text) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: '  $text  ',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final double top =
        at.dy - painter.height - 2 < 0 ? 2 : at.dy - painter.height - 2;
    final Rect bg =
        Rect.fromLTWH(at.dx, top, painter.width + 8, painter.height + 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(bg, const Radius.circular(4)),
      Paint()..color = labelBg,
    );
    painter.paint(canvas, bg.topLeft + const Offset(4, 2));
  }

  @override
  bool shouldRepaint(covariant _BoxPainter oldDelegate) =>
      oldDelegate.boxes != boxes;
}

class _FactRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final TextStyle? valueStyle;

  const _FactRow({
    required this.icon,
    required this.title,
    required this.value,
    this.valueStyle,
  });

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 17, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          // Fixed label column: titles like "Location" must never wrap, and
          // the value takes whatever width is left (right aligned).
          SizedBox(
            width: 92,
            child: Text(
              title,
              style: textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: valueStyle ??
                  textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfidenceRow extends StatelessWidget {
  final double confidence;

  const _ConfidenceRow({required this.confidence});

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              Icons.verified,
              size: 17,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Confidence', style: textTheme.bodyMedium),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: confidence,
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${(confidence * 100).toStringAsFixed(0)}%',
            style: textTheme.titleSmall?.copyWith(color: scheme.primary),
          ),
        ],
      ),
    );
  }
}
