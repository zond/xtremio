import 'package:flutter/material.dart';

import '../../shell/device_profile.dart';

/// An addon's manifest URL, as a details screen shows it.
///
/// A configured addon's URL carries the viewer's keys -- a debrid token, an
/// account's credentials -- in its path as well as its query. On a phone it
/// is shown whole, as selectable text: the screen is the viewer's own and
/// copying it out is what it is there for. **On a television it is shown as
/// its host and an ellipsis**, with a Show button beside it: a television
/// is a screen the whole room reads, and the one a photograph of a bug
/// report is taken of. A URL with nothing past the host but
/// `/manifest.json` has nothing to hide and is shown whole everywhere.
class AddonUrlText extends StatefulWidget {
  const AddonUrlText(this.url, {super.key, this.style, this.textAlign});

  final String url;
  final TextStyle? style;
  final TextAlign? textAlign;

  /// What a television shows before Show is pressed: `host…`, or the whole
  /// URL when [hasNothingToHide].
  static String concealed(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return '…';
    if (hasNothingToHide(url)) return url;
    return '${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/…';
  }

  /// Whether [url] is a bare `scheme://host[:port]/manifest.json`: no user
  /// info, no path of its own, no query, no fragment.
  static bool hasNothingToHide(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.hasAuthority &&
        uri.userInfo.isEmpty &&
        uri.path == '/manifest.json' &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  @override
  State<AddonUrlText> createState() => _AddonUrlTextState();
}

class _AddonUrlTextState extends State<AddonUrlText> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    if (!DeviceScope.isTv(context) ||
        AddonUrlText.hasNothingToHide(widget.url)) {
      return SelectableText(
        widget.url,
        style: widget.style,
        textAlign: widget.textAlign,
      );
    }
    // Beside the text, not inside anything focusable: a button drawn inside
    // a focusable thing is not a button (AGENTS.md).
    return Wrap(
      alignment: widget.textAlign == TextAlign.center
          ? WrapAlignment.center
          : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        // Plain text either way: a remote has nothing to select with, and
        // a selectable text would be one more stop for it to land on.
        Text(
          _revealed ? widget.url : AddonUrlText.concealed(widget.url),
          style: widget.style,
          textAlign: widget.textAlign,
        ),
        TextButton(
          onPressed: () => setState(() => _revealed = !_revealed),
          child: Text(_revealed ? 'Hide' : 'Show'),
        ),
      ],
    );
  }
}
