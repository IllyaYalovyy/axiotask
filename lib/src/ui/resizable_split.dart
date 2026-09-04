// The expanded layout's two draggable splits (#210, split out of
// list_detail_scaffold.dart by #274): the sidebar/list divider and — when a
// detail is open — the list/detail one, plus the handle both of them use.
//
// It lives beside the scaffold rather than inside it because it is a
// self-contained piece of interaction with rules of its own: a drag tracks the
// pointer live, persistence fires exactly once on drag end, and the parent's
// re-seeding must never clobber a drag in flight.

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import 'detail_motion.dart';
import 'list_detail_scaffold.dart';
import 'motion.dart';

/// The expanded-layout body with two draggable dividers (#210): the sidebar/list
/// split and — when a detail is open — the list/detail split. Stateful so a drag
/// tracks the pointer live (setState per frame) while persistence fires only
/// ONCE, on drag end, keeping the prefs write off the per-frame path. The parent
/// re-seeds the local widths only when the persisted props actually change (a
/// drag end reports the same value it holds, so an unrelated rebuild — a new
/// task, a count tick — never clobbers an in-progress or just-finished drag).
class ResizableExpanded extends StatefulWidget {
  const ResizableExpanded({
    super.key,
    required this.sidebar,
    required this.list,
    required this.detail,
    required this.sidebarWidth,
    required this.detailFraction,
    required this.onSidebarWidthChanged,
    required this.onDetailFractionChanged,
    required this.onResetSidebarWidth,
    required this.onResetDetailFraction,
  });

  final Widget sidebar;
  final Widget list;
  final Widget? detail;
  final double sidebarWidth;
  final double detailFraction;
  final ValueChanged<double>? onSidebarWidthChanged;
  final ValueChanged<double>? onDetailFractionChanged;
  final VoidCallback? onResetSidebarWidth;
  final VoidCallback? onResetDetailFraction;

  @override
  State<ResizableExpanded> createState() => ResizableExpandedState();
}

class ResizableExpandedState extends State<ResizableExpanded>
    with SingleTickerProviderStateMixin {
  late double _sidebarWidth = widget.sidebarWidth;
  late double _detailFraction = widget.detailFraction;

  /// The detail pane's arrival and departure (#253), as ONE span: the pane
  /// slides in from the end edge while the list eases to its narrower width,
  /// and only once it has landed does the #221 open-row highlight fade in.
  /// Reversed, the highlight goes first and the pane leaves after it.
  ///
  /// Seeded at its end state when a detail is already open on mount — a window
  /// restored with a task selected did not just open it.
  late final AnimationController _pane = AnimationController(
    vsync: this,
    duration: MotionDurations.detailPane,
    value: widget.detail == null ? 0 : 1,
  );

  /// The pane's own travel: the first beat of [_pane].
  late final CurvedAnimation _slide = CurvedAnimation(
    parent: _pane,
    curve: const Interval(
      0,
      MotionDurations.detailPaneSlideFraction,
      curve: MotionCurves.standard,
    ),
  );

  /// The open-row highlight's arrival: the second beat, which is flat at zero
  /// for the whole of the first.
  late final CurvedAnimation _reveal = CurvedAnimation(
    parent: _pane,
    curve: const Interval(
      MotionDurations.detailPaneSlideFraction,
      1,
      curve: MotionCurves.enter,
    ),
  );

  /// The pane being drawn — [ResizableExpanded.detail] while one is open, and
  /// the last one for as long as it is still sliding out.
  late Widget? _shown = widget.detail;

  @override
  void initState() {
    super.initState();
    _pane.addStatusListener(_onPaneStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pane.duration = Motion.of(context).resolve(MotionDurations.detailPane);
  }

  @override
  void dispose() {
    _slide.dispose();
    _reveal.dispose();
    _pane.dispose();
    super.dispose();
  }

  void _onPaneStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    if (widget.detail != null || _shown == null) return;
    setState(() => _shown = null);
  }

  @override
  void didUpdateWidget(ResizableExpanded oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.detail != null) {
      _shown = widget.detail;
      if (oldWidget.detail == null) _pane.forward();
    } else if (oldWidget.detail != null) {
      _pane.reverse();
    }
    // Only adopt a prop change that did NOT originate from our own drag end
    // (where the incoming value already equals the local one). A cross-rebuild
    // with unchanged props leaves the live drag state untouched.
    if (widget.sidebarWidth != oldWidget.sidebarWidth) {
      _sidebarWidth = widget.sidebarWidth;
    }
    if (widget.detailFraction != oldWidget.detailFraction) {
      _detailFraction = widget.detailFraction;
    }
  }

  void _dragSidebar(double dx) {
    setState(() {
      _sidebarWidth = (_sidebarWidth + dx).clamp(
        ListDetailScaffold.minSidebarWidth,
        ListDetailScaffold.maxSidebarWidth,
      );
    });
  }

  void _resetSidebar() {
    setState(() => _sidebarWidth = ListDetailScaffold.defaultSidebarWidth);
    widget.onResetSidebarWidth?.call();
  }

  void _dragDetail(double dx, double region) {
    if (region <= 0) return;
    setState(() {
      // Dragging the handle right grows the list and shrinks the detail, so the
      // detail fraction falls by the pointer's share of the region.
      _detailFraction = (_detailFraction - dx / region).clamp(
        ListDetailScaffold.minDetailFraction,
        ListDetailScaffold.maxDetailFraction,
      );
    });
  }

  void _resetDetail() {
    setState(() => _detailFraction = ListDetailScaffold.defaultDetailFraction);
    widget.onResetDetailFraction?.call();
  }

  @override
  Widget build(BuildContext context) {
    final detail = _shown;
    return Row(
      children: [
        SizedBox(
          key: const Key('expanded-sidebar'),
          width: _sidebarWidth,
          child: widget.sidebar,
        ),
        ResizeHandle(
          key: const Key('sidebar-resize-handle'),
          semanticLabel: 'Resize sidebar',
          onDelta: _dragSidebar,
          onDragEnd: () => widget.onSidebarWidthChanged?.call(_sidebarWidth),
          onReset: _resetSidebar,
        ),
        Expanded(
          child: detail == null
              ? widget.list
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final region = constraints.maxWidth;
                    // Detail is width-pinned to its fraction of the region; the
                    // list flexes into the remainder, so no configuration
                    // overflows the row (#208 still holds).
                    final detailWidth = _detailFraction * region;
                    // Handle and pane travel as ONE slot, so the list's edge
                    // eases the whole way rather than jumping the handle's
                    // width at the start of the slide.
                    final slotWidth = detailWidth + ResizeHandle.hitWidth;
                    return AnimatedBuilder(
                      animation: _slide,
                      builder: (context, _) {
                        final arrived = _slide.value.clamp(0.0, 1.0);
                        return Row(
                          children: [
                            // The list eases into what the slot leaves it —
                            // and learns how far the pane has come, so the
                            // #221 highlight can wait for it to land.
                            Expanded(
                              child: DetailRevealScope(
                                reveal: _reveal,
                                child: widget.list,
                              ),
                            ),
                            SizedBox(
                              width: slotWidth * arrived,
                              child: ClipRect(
                                clipBehavior: arrived >= 1
                                    ? Clip.none
                                    : Clip.hardEdge,
                                // The pane is LAID OUT at its settled width the
                                // whole way in and anchored to the slot's
                                // leading edge, so it slides in from off the
                                // end edge instead of being squeezed out of a
                                // growing box — a pane that re-laid-out every
                                // frame would reflow its text as it travelled.
                                child: OverflowBox(
                                  alignment: Alignment.centerLeft,
                                  minWidth: slotWidth,
                                  maxWidth: slotWidth,
                                  // A divider you can grab while it is still
                                  // flying in is a wobble, not a control.
                                  child: IgnorePointer(
                                    ignoring: arrived < 1,
                                    child: Row(
                                      children: [
                                        ResizeHandle(
                                          key: const Key(
                                            'detail-resize-handle',
                                          ),
                                          semanticLabel: 'Resize detail panel',
                                          onDelta: (dx) =>
                                              _dragDetail(dx, region),
                                          onDragEnd: () => widget
                                              .onDetailFractionChanged
                                              ?.call(_detailFraction),
                                          onReset: _resetDetail,
                                        ),
                                        SizedBox(
                                          key: const Key('expanded-detail'),
                                          width: detailWidth,
                                          child: detail,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// A draggable divider: a comfortable hit area over the 1px [VerticalDivider],
/// with a column-resize cursor for the mouse and double-click-to-reset. Reports
/// horizontal drag deltas so the parent owns the clamp and the persistence.
class ResizeHandle extends StatelessWidget {
  const ResizeHandle({
    required this.onDelta,
    required this.onDragEnd,
    required this.onReset,
    required this.semanticLabel,
    super.key,
  });

  /// The width of the transparent grab area straddling the 1px divider.
  static const double hitWidth = 11;

  final ValueChanged<double> onDelta;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Track from the very first pixel (no 18px slop dead-zone), so the pane
        // edge follows the pointer 1:1 the instant the drag begins.
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        onDoubleTap: onReset,
        child: Semantics(
          label: semanticLabel,
          child: const SizedBox(
            width: hitWidth,
            child: Center(child: VerticalDivider(width: 1)),
          ),
        ),
      ),
    );
  }
}
