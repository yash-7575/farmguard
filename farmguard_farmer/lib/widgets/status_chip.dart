import 'package:material_ui/material_ui.dart';

/// Small rounded status chip with an optional dot / icon, used for
/// online-offline, monitoring and new-viewed states.
class StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  final Color container;
  final IconData? icon;
  final bool showDot;

  const StatusChip({
    super.key,
    required this.label,
    required this.color,
    required this.container,
    this.icon,
    this.showDot = false,
  });

  const StatusChip.online(this.label, {super.key})
      : color = const Color(0xFF0E9F6E),
        container = const Color(0xFFDCF6EA),
        icon = null,
        showDot = true;

  const StatusChip.offline(this.label, {super.key})
      : color = const Color(0xFFDC2F2F),
        container = const Color(0xFFFCE7E4),
        icon = null,
        showDot = true;

  const StatusChip.newBadge({super.key})
      : label = 'New',
        color = const Color(0xFF074233),
        container = const Color(0xFFD8F4E7),
        icon = null,
        showDot = false;

  /// Source label for a live backend detection (green dot, like Online).
  const StatusChip.live({super.key})
      : label = 'LIVE',
        color = const Color(0xFF0E9F6E),
        container = const Color(0xFFDCF6EA),
        icon = null,
        showDot = true;

  /// Source label for a staged demo record (warm earth tones). Demo records
  /// must always be labelled; a LIVE chip is only ever shown for events
  /// that came from the backend.
  const StatusChip.demo({super.key})
      : label = 'DEMO',
        color = const Color(0xFF8A6B2D),
        container = const Color(0xFFF7E7C4),
        icon = null,
        showDot = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: container,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ] else if (showDot) ...<Widget>[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
