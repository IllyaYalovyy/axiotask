import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/model/search.dart';
import 'search_view_model.dart';

final class SearchOverlay extends StatefulWidget {
  const SearchOverlay({
    required this.viewModel,
    required this.onOpenResult,
    required this.onClose,
    super.key,
  });

  final SearchViewModel viewModel;
  final ValueChanged<TaskSearchResult> onOpenResult;
  final VoidCallback onClose;

  @override
  State<SearchOverlay> createState() => _SearchOverlayState();
}

final class _SearchOverlayState extends State<SearchOverlay> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.viewModel.state.query,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openSelected() {
    final result = widget.viewModel.state.selectedResult;
    if (result != null) widget.onOpenResult(result);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            widget.viewModel.selectNext,
        const SingleActivator(LogicalKeyboardKey.arrowUp):
            widget.viewModel.selectPrevious,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: FocusTraversalGroup(
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          key: const Key('search-input'),
                          controller: _controller,
                          autofocus: true,
                          textInputAction: TextInputAction.search,
                          onChanged: widget.viewModel.setQuery,
                          onSubmitted: (_) => _openSelected(),
                          decoration: const InputDecoration(
                            labelText: 'Search tasks',
                            hintText: 'Title or notes',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Close search',
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: AnimatedBuilder(
                    animation: widget.viewModel,
                    builder: (context, _) {
                      final state = widget.viewModel.state;
                      if (state.failureMessage case final failure?) {
                        return Center(child: Text(failure));
                      }
                      if (state.query.trim().isEmpty) {
                        return const _SearchMessage(
                          icon: Icons.manage_search,
                          message: 'Search task titles and notes',
                        );
                      }
                      if (state.isSearching) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (state.results.isEmpty) {
                        return _SearchMessage(
                          icon: Icons.search_off,
                          message: 'No supported tasks match “${state.query}”',
                        );
                      }
                      return ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: state.results.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, indent: 72),
                        itemBuilder: (context, index) {
                          final result = state.results[index];
                          final matchContext = result.isChildMatch
                              ? 'Matched subtask: ${result.match.title}'
                              : _matchedContext(result);
                          final semantics = result.isChildMatch
                              ? 'Open ${result.parent.title}. Matched subtask '
                                    '${result.match.title}. '
                                    '${result.taskListTitle}.'
                              : 'Open ${result.parent.title}. '
                                    '$matchContext. ${result.taskListTitle}.';
                          return Semantics(
                            label: semantics,
                            button: true,
                            excludeSemantics: true,
                            child: ListTile(
                              key: Key('search-result-$index'),
                              selected: state.selectedIndex == index,
                              leading: Icon(
                                result.isChildMatch
                                    ? Icons.account_tree_outlined
                                    : Icons.task_alt_outlined,
                              ),
                              title: Text(result.parent.title),
                              subtitle: Text(
                                '$matchContext • ${result.taskListTitle}',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                widget.viewModel.selectIndex(index);
                                widget.onOpenResult(result);
                              },
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _matchedContext(TaskSearchResult result) {
  final title = result.matchedFields.contains(TaskSearchField.title);
  final notes = result.matchedFields.contains(TaskSearchField.notes);
  if (title && notes) return 'Matched title and notes';
  return title ? 'Matched title' : 'Matched notes';
}

final class _SearchMessage extends StatelessWidget {
  const _SearchMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          icon,
          size: 44,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(message),
      ],
    ),
  );
}
