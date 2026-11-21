import 'package:flutter/material.dart';

/// Shared responsive layout breakpoints for StiQRbudget.
///
/// - `< 360px`: Narrow screens (Flip cover, narrow folded Fold)
/// - `>= 600px`: Wide screens (unfolded Fold, Duo, iPad/Tablet)
/// - `>= 1000px`: Desktop / wide web screens
class ResponsiveBreakpoints {
  static const double narrow = 360.0;
  static const double tablet = 600.0;
  static const double desktop = 1000.0;

  static bool isNarrow(double width) => width < narrow;
  static bool isWide(double width) => width >= tablet;
  static bool isDesktop(double width) => width >= desktop;

  /// Number of envelope card columns for the given available width.
  static int envelopeColumns(double width) {
    if (width >= desktop) return 3;
    if (width >= tablet) return 2;
    return 1;
  }
}

/// Centers content horizontally and constrains it to [maxWidth] on larger viewports.
class ResponsiveCenter extends StatelessWidget {
  final double maxWidth;
  final EdgeInsetsGeometry? padding;
  final Widget child;

  const ResponsiveCenter({
    super.key,
    this.maxWidth = 720.0,
    this.padding,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    Widget content = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    );
    if (padding != null) {
      content = Padding(padding: padding!, child: content);
    }
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1.0,
      child: content,
    );
  }
}
