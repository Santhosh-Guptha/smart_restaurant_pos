import 'package:flutter/material.dart';

/// Keeps a page readable on large monitors and TVs: the content is centred
/// and never wider than [maxWidth]; on phones and tablets it changes nothing.
class MaxWidthBody extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const MaxWidthBody({super.key, required this.child, this.maxWidth = 1280});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
