import 'addon_descriptor.dart';

/// `InstalledAddonsRequest`: what `Load InstalledAddonsWithFilters` takes.
final class InstalledAddonsRequest {
  const InstalledAddonsRequest({this.type});

  /// A meta type the addons must serve, or null for every addon.
  final String? type;

  factory InstalledAddonsRequest.fromJson(Map<String, dynamic> json) =>
      InstalledAddonsRequest(type: json['type'] as String?);

  Map<String, dynamic> toJson() => {'type': type};

  @override
  bool operator ==(Object other) =>
      other is InstalledAddonsRequest && other.type == type;

  @override
  int get hashCode => type.hashCode;
}

/// One entry of `installed_addons.selectable.types`: `null` is "all".
final class InstalledAddonsTypeOption {
  const InstalledAddonsTypeOption({
    required this.type,
    required this.selected,
    required this.request,
  });

  final String? type;
  final bool selected;

  /// The request to dispatch (`Load InstalledAddonsWithFilters`) to select
  /// this.
  final InstalledAddonsRequest request;

  factory InstalledAddonsTypeOption.fromJson(Map<String, dynamic> json) =>
      InstalledAddonsTypeOption(
        type: json['type'] as String?,
        selected: json['selected'] as bool? ?? false,
        request: InstalledAddonsRequest.fromJson(
          json['request'] as Map<String, dynamic>,
        ),
      );
}

/// View over the `installed_addons` field (`InstalledAddonsWithFilters`, no
/// `rename_all`): the profile's addons filtered by type. Follows the
/// profile once loaded.
final class InstalledAddonsState {
  const InstalledAddonsState({
    required this.selected,
    required this.types,
    required this.addons,
  });

  /// The loaded request, or null when the model is unloaded.
  final InstalledAddonsRequest? selected;

  /// `null` (all) first, then every type an installed addon serves.
  final List<InstalledAddonsTypeOption> types;

  /// The addons matching [selected], in profile order.
  final List<AddonDescriptor> addons;

  factory InstalledAddonsState.fromJson(Map<String, dynamic> json) {
    final selected = json['selected'] as Map<String, dynamic>?;
    final selectable = json['selectable'] as Map<String, dynamic>?;
    return InstalledAddonsState(
      selected: selected == null
          ? null
          : InstalledAddonsRequest.fromJson(
              selected['request'] as Map<String, dynamic>,
            ),
      types: [
        for (final type in (selectable?['types'] as List<dynamic>? ?? const []))
          InstalledAddonsTypeOption.fromJson(type as Map<String, dynamic>),
      ],
      addons: AddonDescriptor.listFromJson(json['catalog']),
    );
  }

  bool get isLoaded => selected != null;

  InstalledAddonsTypeOption? get selectedType =>
      types.where((type) => type.selected).firstOrNull;
}
