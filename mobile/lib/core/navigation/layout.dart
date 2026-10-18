import 'package:flutter/widgets.dart';

/// How much room there is to work with.
///
/// The same screens serve a phone at the counter and a desktop window in the
/// back office. Rather than forking them, each asks what shape it is in and
/// arranges itself: a phone gets one column and a bar along the bottom, a
/// desktop gets the width used and the navigation down the side.
enum WindowSize {
  /// A phone, held in one hand.
  compact,

  /// A tablet, or a desktop window someone has made narrow.
  medium,

  /// A desktop window, or a tablet turned sideways.
  expanded;

  static WindowSize of(BuildContext context) => fromWidth(MediaQuery.sizeOf(context).width);

  /// The breakpoints are Material's: a phone up to 600, a tablet to 840,
  /// anything wider is a desktop window.
  static WindowSize fromWidth(double width) {
    if (width < 600) return WindowSize.compact;
    if (width < 840) return WindowSize.medium;
    return WindowSize.expanded;
  }

  /// Navigation along the bottom, as a phone expects.
  bool get usesBottomBar => this == WindowSize.compact;

  /// Enough room to stand two columns beside each other.
  bool get hasRoomForTwoColumns => this != WindowSize.compact;

  /// Long lines are hard to read, so content stops widening at some point
  /// and sits in the middle of the window instead.
  double get readableWidth => switch (this) {
        WindowSize.compact => double.infinity,
        WindowSize.medium => 760,
        WindowSize.expanded => 1100,
      };
}

/// Keeps a screen's content to a readable width in a wide window, and leaves
/// it alone on a phone.
class ReadableWidth extends StatelessWidget {
  final Widget child;

  /// Overrides the width where a screen wants something other than the usual
  /// — a table that earns more room, say.
  final double? maxWidth;

  const ReadableWidth({super.key, required this.child, this.maxWidth});

  @override
  Widget build(BuildContext context) {
    final limit = maxWidth ?? WindowSize.of(context).readableWidth;
    if (limit == double.infinity) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: limit), child: child),
    );
  }
}

/// A form, centred and kept to the width of a form.
///
/// Fields stretched across a monitor are harder to fill in than fields in a
/// column: the eye loses the line between the label and the box, and the
/// hand travels for no reason. So a form is the same shape on a desktop as
/// on a phone, with the room around it rather than inside it.
class FormPane extends StatelessWidget {
  final Widget child;

  /// Wider for a form that is really a table — a basket of lines, say.
  final double maxWidth;

  const FormPane({super.key, required this.child, this.maxWidth = 640});

  @override
  Widget build(BuildContext context) {
    if (WindowSize.of(context) == WindowSize.compact) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
    );
  }
}

/// A record being read: wider than a form, because it holds figures side by
/// side, but still short of a monitor's full width.
class DetailPane extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const DetailPane({super.key, required this.child, this.maxWidth = 1000});

  @override
  Widget build(BuildContext context) {
    if (WindowSize.of(context) == WindowSize.compact) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
    );
  }
}
