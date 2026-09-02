import 'package:xtremio/shell/external_link.dart';

/// Records every URL handed to it instead of launching anything.
class FakeLinkOpener implements ExternalLinkOpener {
  FakeLinkOpener({this.result = true});

  /// What [open] reports back.
  final bool result;

  /// Every URL passed to [open], in order.
  final List<Uri> opened = [];

  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    return result;
  }
}
