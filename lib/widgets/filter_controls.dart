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

import '../shell/device_profile.dart';

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
///
/// On a TV ([DeviceScope.isTv]) it is a button that opens a menu instead
/// ([_FilterMenuButton]): a [DropdownMenu] that cannot take focus itself
/// is a text field whose only focusable part is its trailing arrow, and
/// the menu it opens highlights entries in step with the arrow keys but
/// picks one only on Enter, which a remote does not send.
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
    if (DeviceScope.isTv(context)) {
      return _FilterMenuButton<R>(
        label: label,
        options: options,
        selectedIndex: selectedIndex,
        onSelect: onSelect,
      );
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

/// [FilterMenu] for a remote: a button reading "Label: selected" that opens
/// a [MenuAnchor] of one focusable [MenuItemButton] per option.
///
/// Opening puts focus on the selected entry (the first, when none is), so
/// up and down start from where the engine is; the menu keeps the D-pad
/// inside itself, select picks the focused entry (or just closes, on the
/// one already selected) and hands focus back to the button. The remote's
/// BACK is a route pop, which would leave the screen with the menu still
/// drawn: while open, a [PopScope] turns it into closing the menu.
class _FilterMenuButton<R> extends StatefulWidget {
  const _FilterMenuButton({
    required this.label,
    required this.options,
    required this.selectedIndex,
    required this.onSelect,
  });

  final String label;
  final List<FilterOption<R>> options;
  final int? selectedIndex;
  final ValueChanged<R> onSelect;

  @override
  State<_FilterMenuButton<R>> createState() => _FilterMenuButtonState<R>();
}

class _FilterMenuButtonState<R> extends State<_FilterMenuButton<R>> {
  final MenuController _controller = MenuController();
  final FocusNode _button = FocusNode(debugLabel: 'filter menu');
  bool _open = false;

  @override
  void dispose() {
    _button.dispose();
    super.dispose();
  }

  void _setOpen(bool open) {
    if (mounted && open != _open) setState(() => _open = open);
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = widget.selectedIndex;
    final selected = selectedIndex == null
        ? null
        : widget.options[selectedIndex].label;
    return PopScope(
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _controller.close();
      },
      child: MenuAnchor(
        controller: _controller,
        childFocusNode: _button,
        onOpen: () => _setOpen(true),
        onClose: () => _setOpen(false),
        menuChildren: [
          for (final (index, option) in widget.options.indexed)
            MenuItemButton(
              autofocus: index == (selectedIndex ?? 0),
              onPressed: () {
                if (!option.selected) widget.onSelect(option.request);
              },
              child: Text(option.label),
            ),
        ],
        builder: (context, controller, _) => OutlinedButton.icon(
          focusNode: _button,
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
          iconAlignment: IconAlignment.end,
          icon: const Icon(Icons.arrow_drop_down),
          label: Text(
            selected == null ? widget.label : '${widget.label}: $selected',
          ),
        ),
      ),
    );
  }
}
