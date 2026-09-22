/// A drawing, not a screen: the details ladder at the density we are
/// considering, so it can be looked at before anything is rebuilt.
///
/// Nothing here is wired to the app. It exists to answer one question --
/// does a collapsed ladder with pills and smaller cards leave room for a
/// recommendations row without the screen becoming a wall -- and it should
/// be deleted once that question is answered.
library;

import 'package:flutter/material.dart';

/// What a rung is called when it is collapsed, and what it holds open.
class Rung {
  const Rung(this.label, {this.summary = '', this.open = false, this.child});
  final String label;
  final String summary;
  final bool open;
  final Widget? child;
}

/// Loaded by the test; a widget test otherwise draws every word as a box.
const _font = 'proto';

const _panel = Color(0xFF1B1D21);
const _card = Color(0xFF26292F);
const _ink = Color(0xFFE7E9EE);
const _dim = Color(0xFF9AA0AA);
const _accent = Color(0xFF7FB2FF);

/// The proposed sizes, in one place so they can be argued with.
class Density {
  static const double pillHeight = 36;
  static const double sourceWidth = 260;
  static const double sourceHeight = 96;
  static const double posterWidth = 120;
  static const double posterHeight = 180;
  static const double rungHeaderHeight = 44;
}

class DetailsPrototype extends StatelessWidget {
  const DetailsPrototype({
    super.key,
    required this.rungs,
    required this.focused,
  });

  final List<Rung> rungs;

  /// Which rung has the remote, drawn with the focus ring.
  final int focused;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Container(
      color: const Color(0xFF111316),
      padding: const EdgeInsets.fromLTRB(48, 28, 48, 28),
      // Scrolls, as the real screen does: what is worth seeing is how much
      // has to scroll, not whether it fits exactly.
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Header(),
            const SizedBox(height: 18),
            for (final (i, rung) in rungs.indexed) ...[
              _RungView(rung: rung, focused: i == focused),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 74,
        height: 110,
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Avalon',
              style: TextStyle(
                fontFamily: _font,
                color: _ink,
                fontSize: 30,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '2001 · 106 min · Science fiction · Mamoru Oshii',
              style: TextStyle(fontFamily: _font, color: _dim, fontSize: 15),
            ),
            const SizedBox(height: 8),
            const Text(
              'A sepia Poland, an illegal combat game, and a player who cannot '
              'tell which layer she is standing in.',
              maxLines: 2,
              style: TextStyle(
                fontFamily: _font,
                color: _dim,
                fontSize: 14,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _RungView extends StatelessWidget {
  const _RungView({required this.rung, required this.focused});
  final Rung rung;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final header = Container(
      height: Density.rungHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: focused ? _accent : Colors.transparent,
          width: 2,
        ),
      ),
      child: Row(
        children: [
          Icon(
            rung.open ? Icons.expand_more : Icons.chevron_right,
            size: 20,
            color: focused ? _accent : _dim,
          ),
          const SizedBox(width: 8),
          Text(
            rung.label,
            style: TextStyle(
              fontFamily: _font,
              color: focused ? _ink : _dim,
              fontSize: 16,
              fontWeight: focused ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          const Spacer(),
          if (rung.summary.isNotEmpty)
            Text(
              rung.summary,
              style: const TextStyle(
                fontFamily: _font,
                color: _dim,
                fontSize: 14,
              ),
            ),
        ],
      ),
    );
    if (!rung.open || rung.child == null) return header;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [header, const SizedBox(height: 8), rung.child!],
    );
  }
}

/// Resolutions as pills rather than as cards carrying a summary line.
class ResolutionPills extends StatelessWidget {
  const ResolutionPills({super.key, this.chosen = 0});
  final int chosen;

  static const labels = ['2160p · 14', '1080p · 31', '720p · 8', 'Other · 5'];

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final (i, label) in labels.indexed) ...[
        Container(
          height: Density.pillHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: i == chosen ? _accent.withValues(alpha: 0.18) : _card,
            borderRadius: BorderRadius.circular(Density.pillHeight / 2),
            border: Border.all(
              color: i == chosen ? _accent : Colors.transparent,
              width: 2,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: _font,
              color: i == chosen ? _ink : _dim,
              fontSize: 15,
              fontWeight: i == chosen ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(width: 10),
      ],
    ],
  );
}

/// A source at the proposed size: the release name, then one line of facts.
class SourceCards extends StatelessWidget {
  const SourceCards({super.key, this.highlight = -1});
  final int highlight;

  static const rows = [
    ('Avalon.2001.1080p.BluRay.x264-CiNEFiLE', '👤 42 · 8.7 GB · Torrentio'),
    ('Avalon 2001 REMASTERED 1080p BluRay FLAC2.0', '👤 18 · 12.1 GB · Comet'),
    ('Avalon.2001.PL.1080p.WEB-DL.H264-Zombi', '👤 6 · 4.3 GB · Torrentio'),
    ('Avalon.2001.1080p.AMZN.WEB-DL.DDP2.0', '👤 3 · 5.9 GB · MediaFusion'),
  ];

  @override
  Widget build(BuildContext context) => SizedBox(
    height: Density.sourceHeight,
    child: Row(
      children: [
        for (final (i, row) in rows.indexed) ...[
          Container(
            width: Density.sourceWidth,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: i == highlight ? _accent : Colors.transparent,
                width: 2,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    row.$1,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: _font,
                      color: _ink,
                      fontSize: 15,
                      height: 1.25,
                    ),
                  ),
                ),
                Text(
                  row.$2,
                  style: const TextStyle(
                    fontFamily: _font,
                    color: _dim,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
        ],
      ],
    ),
  );
}

/// The new row: posters drawn small, because this one is for browsing.
class RecommendationRow extends StatelessWidget {
  const RecommendationRow({super.key, this.focused = -1});
  final int focused;

  static const films = [
    ('Ghost in the Shell', '1995'),
    ('Stalker', '1979'),
    ('Le Samouraï', '1967'),
    ('eXistenZ', '1999'),
    ('Kanal', '1957'),
    ('Ivan\'s Childhood', '1962'),
    ('Seconds', '1966'),
  ];

  @override
  Widget build(BuildContext context) => SizedBox(
    height: Density.posterHeight + 42,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, film) in films.indexed) ...[
          SizedBox(
            width: Density.posterWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: Density.posterWidth,
                  height: Density.posterHeight,
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: i == focused ? _accent : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  film.$1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: _font,
                    color: i == focused ? _ink : _dim,
                    fontSize: 13,
                  ),
                ),
                Text(
                  film.$2,
                  style: const TextStyle(
                    fontFamily: _font,
                    color: _dim,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
        ],
      ],
    ),
  );
}

/// The one card that carries on from where the viewer left off.
class ContinueCard extends StatelessWidget {
  const ContinueCard({super.key, this.focused = true});
  final bool focused;

  @override
  Widget build(BuildContext context) => Container(
    width: 420,
    height: Density.sourceHeight,
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
    decoration: BoxDecoration(
      color: const Color(0xFF2B2F3A),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color: focused ? _accent : Colors.transparent,
        width: 2,
      ),
    ),
    child: Row(
      children: [
        const Icon(Icons.play_arrow, color: _accent, size: 34),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Continue with last source',
                style: TextStyle(
                  fontFamily: _font,
                  color: _ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Avalon.2001.1080p.BluRay.x264-CiNEFiLE · 48 min left',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: _font, color: _dim, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
