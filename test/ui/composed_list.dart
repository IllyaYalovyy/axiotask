// The list pane as the APP mounts it (#274): the one composer above the view
// switch, the list below it.
//
// [TaskListView] no longer owns the quick-add composer — [ComposerHost] does,
// so that a view switch (which mounts two panes at once) can never produce two
// of them. Any suite that pumps the pane directly has to mount the host too, or
// it is testing a list with no way to create a task; this is that wrapper, in
// one place, so the suites cannot drift from the shell's own composition.

import 'package:axiotask/src/ui/composer_controller.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:flutter/material.dart';

Widget composedList({
  required String viewId,
  String? selectedTaskId,
  ValueChanged<String>? onOpenTask,
  ValueChanged<String>? onOpenTaskNotes,
  void Function(String viewId, String taskId)? onOpenInView,
}) => ComposerHost(
  viewId: viewId,
  selectedTaskId: selectedTaskId,
  onOpenTask: onOpenTask,
  onOpenInView: onOpenInView,
  child: TaskListView(
    viewId: viewId,
    selectedTaskId: selectedTaskId,
    onOpenTask: onOpenTask ?? (_) {},
    onOpenTaskNotes: onOpenTaskNotes,
    onOpenInView: onOpenInView,
  ),
);
