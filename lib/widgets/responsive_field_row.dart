import 'package:flutter/material.dart';

/// Form fields side by side when there is room, stacked when there is not.
///
/// Settings and dialogs put two or three text fields in a `Row` of
/// `Expanded`s. On a 360 px phone that gives each field ~100 px and cuts the
/// label to a few letters. This lays them out in a row only when every field
/// gets at least [minFieldWidth]; otherwise one per line.
class ResponsiveFieldRow extends StatelessWidget {
  final List<Widget> children;
  final List<int>? flex;
  final double spacing;
  final double minFieldWidth;
  final CrossAxisAlignment crossAxisAlignment;

  const ResponsiveFieldRow({
    super.key,
    required this.children,
    this.flex,
    this.spacing = 12,
    this.minFieldWidth = 220,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  @override
  Widget build(BuildContext context) {
    // Screen width, not a LayoutBuilder: these rows sit inside AlertDialogs,
    // which size their content intrinsically and can't host a LayoutBuilder.
    // The page gutters and dialog insets are allowed for with 64 px.
    final n = children.length;
    final needed = n * minFieldWidth + (n - 1) * spacing;
    final available = MediaQuery.sizeOf(context).width - 64;
    if (available >= needed) {
      return Row(
        crossAxisAlignment: crossAxisAlignment,
        children: [
          for (var i = 0; i < n; i++) ...[
            if (i > 0) SizedBox(width: spacing),
            Expanded(flex: (flex != null && i < flex!.length) ? flex![i] : 1, child: children[i]),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < n; i++) ...[
          if (i > 0) SizedBox(height: spacing),
          children[i],
        ],
      ],
    );
  }
}
