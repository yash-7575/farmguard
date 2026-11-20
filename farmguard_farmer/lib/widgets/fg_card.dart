import 'package:material_ui/material_ui.dart';

/// A rounded white card with a subtle border — the app's base container.
///
/// Mirrors the skill's `Card(onClick, shape: RoundedCornerShape(12.dp))`
/// pattern with a restrained, border-first elevation treatment.
class FgCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final double radius;

  const FgCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.color,
    this.radius = 16,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius borderRadius = BorderRadius.circular(radius);
    return Material(
      color: color ?? scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
