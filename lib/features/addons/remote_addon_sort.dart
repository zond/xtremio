import '../../core/core.dart';

/// How the Community list is ordered.
///
/// Two orders, because two are all a directory entry gives us to order by:
/// it is a transport URL and a manifest, and nothing in either says how
/// many people use the addon. Sorting by popularity is the thing a
/// directory of six hundred addons most wants, and it is not on offer --
/// stremio-addons.net's catalogue declares no `extra`, so there is no sort
/// to ask it for, and asking anyway (`.../sort=popular.json`) is a 404.
/// What that site ranks on the web does not reach the addon protocol, and
/// what does reach us carries no count to rank by ourselves.
enum RemoteAddonSort {
  /// The order the catalogue sent, which is the directory's own ranking --
  /// whatever it ranks on. The default, because it is the one order here
  /// that carries an opinion we did not compute ourselves.
  catalogOrder('Catalog order'),

  /// By name, which is what makes a list of several hundred addons one a
  /// viewer can find a name they already know in.
  name('Name A–Z');

  const RemoteAddonSort(this.label);

  final String label;
}

/// [addons] in [sort]'s order, ties keeping the order they arrived in.
///
/// This orders what has been *loaded*, not the catalogue: a list that pages
/// in as it is scrolled is sorted again as each page lands, so the order is
/// right for what is on screen rather than for a list we do not have.
List<AddonDescriptor> sortedRemoteAddons(
  List<AddonDescriptor> addons,
  RemoteAddonSort sort,
) {
  if (sort == RemoteAddonSort.catalogOrder) return addons;
  final ranked = [
    for (var index = 0; index < addons.length; index++)
      (index, addons[index].manifest.name.toLowerCase(), addons[index]),
  ]..sort((a, b) => a.$2 == b.$2 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [for (final entry in ranked) entry.$3];
}
