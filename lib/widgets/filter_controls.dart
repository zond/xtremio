/// Filter controls shared by the screens that browse an engine-filtered
/// list (Discover's `CatalogWithFilters`, the Library's
/// `LibraryWithFilters`).
///
/// They are stateless on purpose: every option carries the request the
/// engine attached to it, a tap hands that request to `onSelect` verbatim,
/// and the control re-renders from the next state's `selected` flags. No
/// selection is tracked here.
library;

import 'package:flutter/material.dart';

/// One selectable entry of a filter: what to show, whether the engine flags
/// it as the current one, and the request to dispatch to select it.
final class FilterOption<R> {
  const FilterOption({
    required this.label,
    required this.selected,
    required this.request,
  });

  /// Display-ready label.
  final String label;
  final bool selected;
  final R request;
}

/// The options as a segmented button (wide layouts).
class FilterSegments<R> extends StatelessWidget {
  const FilterSegments({
    super.key,
    required this.options,
    required this.onSelect,
  });

  final List<FilterOption<R>> options;
  final ValueChanged<R> onSelect;

  @override
  Widget build(BuildContext context) => SegmentedButton<int>(
    showSelectedIcon: false,
    segments: [
      for (final (index, option) in options.indexed)
        ButtonSegment(value: index, label: Text(option.label)),
    ],
    selected: {
      for (final (index, option) in options.indexed)
        if (option.selected) index,
    },
    emptySelectionAllowed: true,
    onSelectionChanged: (selection) {
      if (selection.isNotEmpty) onSelect(options[selection.first].request);
    },
  );
}

/// The options as choice chips (narrow layouts).
class FilterChips<R> extends StatelessWidget {
  const FilterChips({super.key, required this.options, required this.onSelect});

  final List<FilterOption<R>> options;
  final ValueChanged<R> onSelect;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    children: [
      for (final option in options)
        ChoiceChip(
          label: Text(option.label),
          selected: option.selected,
          onSelected: (_) {
            if (!option.selected) onSelect(option.request);
          },
        ),
    ],
  );
}

/// A read-only dropdown over [options]; the selected one is the entry the
/// engine flagged, so a new state moves the selection without local state.
class FilterMenu<R> extends StatelessWidget {
  const FilterMenu({
    super.key,
    required this.label,
    required this.options,
    required this.onSelect,
  });

  final String label;
  final List<FilterOption<R>> options;
  final ValueChanged<R> onSelect;

  @override
  Widget build(BuildContext context) {
    int? selectedIndex;
    for (final (index, option) in options.indexed) {
      if (option.selected) {
        selectedIndex = index;
        break;
      }
    }
    return DropdownMenu<int>(
      // A new option list (another type or catalog) gets a fresh menu, so
      // its text never shows an entry that no longer exists.
      key: ValueKey(
        Object.hashAll([label, for (final option in options) option.label]),
      ),
      label: Text(label),
      initialSelection: selectedIndex,
      requestFocusOnTap: false,
      inputDecorationTheme: const InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(),
        constraints: BoxConstraints(maxHeight: 44),
      ),
      dropdownMenuEntries: [
        for (final (index, option) in options.indexed)
          DropdownMenuEntry(value: index, label: option.label),
      ],
      onSelected: (index) {
        if (index != null && !options[index].selected) {
          onSelect(options[index].request);
        }
      },
    );
  }
}
