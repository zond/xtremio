part of 'player_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// What the auto-pick is looking for, from whichever of the two answers
/// there is: the engine's session preference, or what this show was last
/// watched with (`SubtitlePickMemory`).
///
/// One shape for both so there is one piece of code that applies it. What
/// the two can say differs -- only the memory names a release group, and
/// only it survives the app being closed -- but what is *done* about it
/// must not, or the file a viewer gets would depend on which memory
/// answered.
final class _WantedSubtitle {
  const _WantedSubtitle({
    required this.enabled,
    required this.language,
    this.releaseGroup,
    this.embeddedFirst = false,
  });

  /// False means subtitles off, and it is an answer rather than the
  /// absence of one: a viewer who turned them off is not asking to be
  /// asked again next episode.
  final bool enabled;

  /// The label the menu prints (`Swedish`), not the code; null matches
  /// any language, which is what an enabled preference naming none does.
  final String? language;

  /// The lower-cased release group to prefer among that language's files,
  /// when one is remembered. Only a preference: nothing here refuses a
  /// language because the group it named is not on offer this episode.
  final String? releaseGroup;

  /// Whether a track inside the video wins over an addon's file of the
  /// same language.
  final bool embeddedFirst;
}

/// Subtitles: picks by hand and the auto-pick, timing and what is
/// remembered of it, matching against another file, and the menus.
extension _PlayerSubtitles on _PlayerScreenState {
  /// What to call the addon a subtitle file came from: the installed
  /// addon's own name, else the host its manifest URL names -- the same
  /// fallback the sources list uses.
  String _subtitleAddonName(String manifestUrl) =>
      _profile?.installedAddon(manifestUrl)?.manifest.name ??
      Uri.tryParse(manifestUrl)?.host ??
      manifestUrl;

  /// mpv could not load the addon file at [url]: say so, and put back
  /// what it was meant to replace -- mpv never took it off, since
  /// `sub-add` changes the selection only when the file is in. A pick the
  /// auto-pick made is made again, past the dead file.
  void _onSubtitleFailed(String url) {
    DiagnosticsLog.warn('player', 'subtitle file not loaded: $url');
    _deadSubtitles.add(url);
    final pick = _subtitlePick;
    if (!_stillOurs ||
        pick == null ||
        pick.url != url ||
        _tracks.value.activeSubtitleId != url) {
      return;
    }
    _subtitlePick = null;
    final subtitle = _externalSubtitle;
    _undoSubtitlePick(pick.before, pick.beforeSubtitle);
    _showSubtitleFailure(
      subtitle == null
          ? 'This subtitle could not be loaded.'
          : 'The subtitle "${SubtitleMenu.externalLabel(subtitle)}" could '
                'not be loaded.',
    );
    if (pick.auto) {
      _autoPickedSubtitles = false;
      _maybeAutoPickSubtitles();
    }
  }

  /// Puts the tracks back to [before] and the timing to [beforeSubtitle]'s.
  ///
  /// Reverting is a change of what is on screen like any other, so the
  /// multiplier comes back with it -- and this is the one path that moves
  /// the timing outside a build: the panel is drawn from [_timing], so
  /// without the rebuild it would go on showing the shift and the
  /// multiplier mpv has already been taken off.
  void _undoSubtitlePick(PlaybackTracks before, SubtitleInfo? beforeSubtitle) {
    _tracks.value = before;
    setState(() => _resetSubtitleTiming(beforeSubtitle));
  }

  void _showSubtitleFailure(String message) {
    _subtitleFailureTimer?.cancel();
    setState(() => _subtitleFailure = message);
    _subtitleFailureTimer = Timer(PlayerScreen.subtitleFailureShown, () {
      _subtitleFailureTimer = null;
      if (mounted) setState(() => _subtitleFailure = null);
    });
  }

  /// Puts libmpv's subtitle multiplier and offset back to untouched --
  /// 1.0 and 0.0 -- and records [subtitle] as the addon file they now
  /// belong to, or null when what is shown is not one.
  ///
  /// Every path that changes what is on screen calls this, which is the
  /// whole of the reset rule: the timing belongs to the player, not to
  /// the file, so one left behind by the previous pick would silently
  /// ruin a subtitle that was correct. An offset made for a file that
  /// started late is nonsense on the next one, and mpv keeps `sub-delay`
  /// across a track change exactly as it keeps `sub-speed`.
  ///
  /// Nothing but the viewer ever moves either value away from untouched,
  /// so this is also the only thing that undoes their work: an
  /// adjustment is theirs from the first press until something changes
  /// what is shown.
  void _resetSubtitleTiming([SubtitleInfo? subtitle]) {
    // Before anything moves: a press a moment ago belongs to the file
    // that is on its way out, not to the one replacing it.
    _flushRememberedTiming();
    _externalSubtitle = subtitle;
    // A count measured against the file going off says nothing about the
    // one coming on, and left on screen it would look like a claim about
    // it.
    _subtitleMatchNote = null;
    // The same for the marks, and worse: a mark is a point on the old
    // file's timeline, so one left behind would pair with the next file's
    // marks to give a lever arm across two files and a rate solved from
    // neither.
    _calibration = SubtitleCalibration.none;
    _markNote = null;
    _timing = _rememberedTiming(subtitle);
    _applySubtitleTiming();
  }

  /// What the viewer is remembered to have fixed about [subtitle] here,
  /// and untouched when nothing is -- which is every embedded track,
  /// every subtitle turned off, and every file from an addon that names
  /// no release group.
  ///
  /// The two halves are looked up under different keys because they have
  /// different causes: the speed under the series and the release group,
  /// since what a file was timed against is a property of where it came
  /// from; the offset under the video release as well, since it is the
  /// video's pre-roll less whatever the subtitle's source assumed. See
  /// [SubtitleSyncMemory].
  ///
  /// Both come back as the measured halves of a [SubtitleTiming] rather
  /// than as presses, because that is what they were when they were
  /// written: a ratio and an offset in seconds, which no whole number of
  /// presses names. The presses then count on top, so the first shift
  /// after a file is put back moves it by a tenth from where it was left
  /// rather than from nothing.
  SubtitleTiming _rememberedTiming(SubtitleInfo? subtitle) {
    final memory = _prefs?.subtitleSync;
    final releaseGroup = subtitle?.releaseGroupKey;
    if (memory == null || releaseGroup == null) return const SubtitleTiming();
    final series = _syncSeries;
    final seconds = memory.shiftSecondsFor(
      series: series,
      releaseGroup: releaseGroup,
      release: _syncRelease,
    );
    return SubtitleTiming(
      // Nothing remembered is what nothing applied looks like, so a
      // stored zero and a stored 1.0 both come back as untouched rather
      // than as a correction Reset would offer to undo.
      calibratedSpeed: _rememberedSpeed(memory, series, releaseGroup),
      calibratedDelay: seconds == 0 ? null : seconds,
    );
  }

  /// The multiplier [memory] holds for [releaseGroup]'s files of
  /// [series], and null when it holds none this build will put on a
  /// player.
  ///
  /// The file is forgiving by design and this is the one place a number
  /// out of it becomes `sub-speed`, so the range is checked here rather
  /// than there. media_kit writes the property with
  /// `mpv_set_property_string` and throws the return code away, so a
  /// value outside `<0.1-10.0>` is refused in silence and the multiplier
  /// the *previous* file left behind stays in force while the panel
  /// claims a new one -- a hand-edited preferences file is not worth
  /// that. A stored 1.0 is the file's own timing and is nothing applied,
  /// which is what nothing remembered looks like too.
  double? _rememberedSpeed(
    SubtitleSyncMemory memory,
    String? series,
    String releaseGroup,
  ) {
    final stored = memory.speedFor(series: series, releaseGroup: releaseGroup);
    if (stored == null || stored == 1) return null;
    return stored >= minSubtitleSpeed && stored <= maxSubtitleSpeed
        ? stored
        : null;
  }

  /// The show or film an adjustment made here belongs to: the meta item's
  /// id and not the episode's, because a subtitle group is timed against
  /// a series and not against one of its episodes.
  ///
  /// Read off the request rather than the loaded meta item, which is a
  /// resource that may still be in flight while the subtitle it would key
  /// is already on screen. Null -- an offline play, a stream with no meta
  /// behind it -- means nothing is remembered.
  String? get _syncSeries {
    final id = _state?.metaRequest?.path.id.trim();
    return id == null || id.isEmpty ? null : id;
  }

  /// The video release an offset was measured against: the best filename
  /// known ([castFilename] -- the file the server says it opened, else
  /// the addon's claim about what it linked to), as a bare lower-case
  /// name.
  ///
  /// The whole filename rather than a release group parsed out of it. A
  /// parse is a guess, and the same evening's worth of pre-roll is a
  /// property of the exact file: two encodes by one group can still start
  /// in different places. A narrower key is forgotten more often, which is
  /// the price of never being wrong.
  String? get _syncRelease {
    final name = castFilename(_state, serverFilename: _serverFilename);
    if (name == null) return null;
    final file = name.split(RegExp(r'[/\\]')).last.trim().toLowerCase();
    return file.isEmpty ? null : file;
  }

  /// [sources] in the order both of the list's consumers offer them: the
  /// menu, and the auto-pick that applies a file with nobody looking.
  ///
  /// One place, because a consumer that skipped the ordering would apply
  /// whichever addon answered first -- and the ranking is read from the
  /// same three things a correction is: the release the server named,
  /// the series, and what the viewer has already fixed. A third consumer
  /// calls this too.
  List<SubtitleSource> _offeredSubtitles(Iterable<SubtitleSource> sources) =>
      subtitlesByRelease(
        sources,
        release: _syncRelease,
        series: _syncSeries,
        memory: _prefs?.subtitleSync ?? SubtitleSyncMemory.empty,
      );

  /// Holds what is on screen now for [_flushRememberedTiming] to write,
  /// replacing whatever was waiting.
  ///
  /// Everything the write needs is read here rather than when it is
  /// made, so that what is written down is the file the press was made
  /// on however long the panel then stays up.
  void _rememberTiming() {
    final releaseGroup = _externalSubtitle?.releaseGroupKey;
    final series = _syncSeries;
    final release = _syncRelease;
    // What is on the player, not how it got there: a toggle, a
    // calibration and a match all arrive at one multiplier and one
    // offset, and next episode only the two numbers matter. 1.0 and 0.0
    // are what untouched looks like, and untouched is forgotten.
    final speed = _timing.speed == 1 ? null : _timing.speed;
    final shiftSeconds = _timing.delay;
    _pendingSync = null;
    // No release group from the addon, or no series: there is nothing to
    // key the adjustment on, and applying it to the files it might belong
    // to is worse than forgetting it.
    if (releaseGroup == null || series == null) return;
    _pendingSync = () {
      final prefs = _prefs;
      if (prefs == null) return;
      prefs
          .setSubtitleSync(
            prefs.subtitleSync.remembering(
              series: series,
              releaseGroup: releaseGroup,
              release: release,
              speed: speed,
              shiftSeconds: shiftSeconds,
            ),
          )
          .ignore();
    };
  }

  /// Makes the waiting write, if there is one: the adjusting is over.
  ///
  /// Called when the panel closes, before anything changes what is on
  /// screen, and on the way out. The first of those is the ordinary one;
  /// the second is what keeps a press made a moment ago from being
  /// dropped by the next press on the file that replaced it.
  void _flushRememberedTiming() {
    final pending = _pendingSync;
    _pendingSync = null;
    pending?.call();
  }

  /// Puts the addon file back that a re-open took away, before the timing
  /// made for it is written again.
  ///
  /// `open` is `loadfile`, which drops every subtitle `sub-add` put in --
  /// [MediaKitEngine.open] clears its own record of them for the same
  /// reason -- and mpv then selects by its own rules, typically a
  /// default-flagged embedded track. Nothing else re-adds it: the
  /// auto-pick has counted itself done and a re-open does not re-arm it,
  /// so without this the viewer loses the file they chose and inherits
  /// its multiplier on a track that was in step.
  void _restoreExternalSubtitle() {
    final subtitle = _externalSubtitle;
    if (subtitle == null) return;
    _addExternalSubtitle(subtitle)?.ignore();
  }

  /// Hands [subtitle]'s file to the engine, named the way the menu names
  /// it.
  Future<void>? _addExternalSubtitle(SubtitleInfo subtitle) =>
      _engine?.setExternalSubtitle(
        subtitle.url,
        title: SubtitleMenu.externalLabel(subtitle),
        language: subtitle.lang.isEmpty ? null : subtitle.lang,
      );

  /// Writes [_timing] to the player: the multiplier and the offset
  /// together, always both, so neither can be left holding a value the
  /// other half of the pair has moved on from.
  void _applySubtitleTiming() {
    final engine = _engine;
    if (engine == null) return;
    engine.setSubtitleSpeed(_timing.speed);
    engine.setSubtitleDelay(_timing.delay);
  }

  /// A press on the timing panel. The panel is rebuilt from [_timing], so
  /// what it draws is what mpv is really playing.
  ///
  /// It ends the auto-pick ([_subtitlesChosenByHand]): a viewer judging
  /// the subtitle in front of them has answered the question the session
  /// preference exists to guess at, and a guess that keeps swapping the
  /// file under them is the wrong half of that answer.
  ///
  /// And it is the only path that remembers anything. Every *other* call
  /// on the timing is the machine putting a file back the way it was
  /// found ([_resetSubtitleTiming]), which is not a judgement about
  /// anything and must not be written down as one -- Reset on the panel
  /// is a judgement, and comes through here.
  void _adjustTiming(SubtitleTiming timing) {
    if (timing == _timing) return;
    _subtitlesChosenByHand = true;
    setState(() => _timing = timing);
    _applySubtitleTiming();
    _rememberTiming();
  }

  /// The panel's Reset: back to untouched, and the marks with it.
  ///
  /// Reset is the viewer undoing their own work, and the marks *are*
  /// that work -- what is on `sub-speed` and `sub-delay` after two of
  /// them is the line through them, so putting the two numbers back
  /// without dropping the points they came from undoes nothing. The
  /// next mark would join a pair the viewer has just discarded, which is
  /// still the widest pair and so still the answer, and the panel
  /// would go on saying the episode was fixed over a row reading 1.000x
  /// and +0.0 s. Short of switching files there would then be no way to
  /// take back a mark at all.
  ///
  /// It is not [_resetSubtitleTiming]: that one is the machine putting a
  /// file back the way it found it and deliberately does not remember
  /// what it did. This is a press, so it goes through [_adjustTiming]
  /// like every other press -- back to untouched is *forgotten* rather
  /// than stored as a zero, which is what that path already does.
  void _undoSubtitleTiming() {
    _calibration = SubtitleCalibration.none;
    setState(() => _markNote = null);
    _adjustTiming(const SubtitleTiming());
  }

  /// A press of "This is right": the line on screen is where it belongs,
  /// which is one mark.
  ///
  /// The mark pairs the cue's raw time in the file
  /// ([PlaybackEngine.subtitleCueStart]) with the video position that cue
  /// is *drawn* at under the transform the viewer has just approved --
  /// `speed * cue + delay` -- and never with the position the button was
  /// pressed at. **A cue is on screen for seconds and the property
  /// answers throughout them**, so the press instant is the viewer's
  /// reaction time and not a measurement of anything: taken as the mark,
  /// it would push a subtitle that was already in step late by however
  /// long they took to press, off the button that says it was right, and
  /// would put a second or two of reaction into each end of the lever arm
  /// a rate is read off -- [SubtitleCalibration.rateSpan] is sized for a
  /// tenth of a second of error at each end, and this is twenty times
  /// that.
  ///
  /// So a single mark changes nothing, and that is the shape of the
  /// feature rather than a hole in it: the viewer has already shifted the
  /// line into place by hand, and the mark only writes down where they
  /// put it. What learns a rate is a *second* mark far off, made after
  /// shifting the picture into place again out there, which is what the
  /// shift's strides exist for. The two are points on one line because
  /// each is the viewer's judgement about where a cue belongs, and that
  /// stays true whatever transform was in force when it was made -- which
  /// is what [SubtitleCalibration] fits, and why a mark is not the shift
  /// in force written down.
  ///
  /// The answer is dropped if the subtitle changed while the read was
  /// out: a property read is not the seconds-long fetch a match is, but a
  /// mark landing on the file that replaced the one it was made against
  /// is the same wrong answer.
  Future<void> _markSubtitleTiming() async {
    final engine = _engine;
    if (engine == null) return;
    final marked = _externalSubtitle?.url;
    final cueStart = await engine.subtitleCueStart();
    if (!_stillOurs || _externalSubtitle?.url != marked) return;
    if (cueStart == null) {
      // Between two lines, or subtitles off: there is nothing on screen
      // the viewer can have been pointing at, and a mark invented from
      // the position would say the file is already right.
      setState(() => _markNote = subtitleNoCueNote);
      return;
    }
    // What mpv is drawing that cue at, which is what `_timing` is: it is
    // the only thing written to either property, so the picture the
    // viewer judged is this line at this cue.
    final inForce = _timing;
    final result = _calibration.marking(
      SubtitleMark(
        cueStart: cueStart,
        videoPosition: inForce.speed * cueStart + inForce.delay,
      ),
      inForce: inForce,
    );
    _calibration = result.calibration;
    setState(() => _markNote = result.outcome.note);
    // Through the ordinary press path, because that is what it is: the
    // viewer judged the picture in front of them, so the answer is
    // theirs to keep and is remembered under the same keys as a shift.
    _adjustTiming(result.timing);
  }

  /// Whether any file *other* than the one playing is on offer, which is
  /// what a match can be measured against.
  ///
  /// Nothing about matching is drawn without one: with a single file
  /// there is nothing to compare it with, and an embedded track has no
  /// URL to fetch at all. Hiding it is the honest answer -- an offered
  /// control that cannot work says the app has a way of fixing this
  /// video that it has not got.
  bool _hasOtherSubtitleFile(PlayerState? state) {
    final playing = _externalSubtitle?.url;
    if (playing == null || state == null) return false;
    return state.externalSubtitleSources.any(
      (source) => source.subtitle.url != playing,
    );
  }

  /// Asks which file to measure the playing one against, and measures it.
  ///
  /// The list is the subtitle menu's own ordering, so what is at the head
  /// of a language here is what the addon says was cut for this release --
  /// the likeliest to be in sync, which is the whole of what makes a
  /// reference worth choosing. The choice itself is the viewer's, because
  /// nothing else knows.
  Future<void> _openSubtitleMatch() async {
    final playing = _externalSubtitle;
    if (playing == null) return;
    SubtitleInfo? reference;
    await _showSheet(
      (context) => ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: _player!,
        builder: (context, json, _) {
          final state = _stateOf(json);
          return SubtitleReferenceMenu(
            groups: _subtitleGroups(state),
            playingId: playing.url.toString(),
            onPick: (subtitle) {
              reference = subtitle;
              Navigator.of(context).pop();
            },
          );
        },
      ),
    );
    final picked = reference;
    if (picked != null && _stillOurs) await _matchSubtitleTo(playing, picked);
  }

  /// Measures [playing] against [reference] and applies the answer, or
  /// says why it did not.
  ///
  /// The score is what is shown either way. A pair that does not match --
  /// two files for different episodes, half a film against a whole one, a
  /// reference that is itself adrift -- comes back with the same number in
  /// it, and with the transform beside it, which is what makes the refusal
  /// something the viewer can judge instead of an apology. A fraction of
  /// cues is what this replaced: it is not comparable between a file that
  /// merges lines and one that does not, and it sent the owner looking for
  /// a different reference when the reference was fine.
  ///
  /// A convincing answer goes through [_adjustTiming] like a press does,
  /// because it is one: the viewer chose the file it was measured
  /// against, so the result is their judgement and not the machine
  /// putting anything back.
  Future<void> _matchSubtitleTo(
    SubtitleInfo playing,
    SubtitleInfo reference,
  ) async {
    final client = _subtitleMatchClient;
    if (client == null || _matchingSubtitle) return;
    setState(() {
      _matchingSubtitle = true;
      _subtitleMatchNote = null;
    });
    SubtitleMatch? match;
    String note;
    try {
      match = await client.match(
        playing: playing.url,
        reference: reference.url,
      );
      note = subtitleMatchNote(match);
    } on Object {
      // One sentence for every failure: what went wrong is a fetch of a
      // URL, and an addon's subtitle URL can carry a debrid API key,
      // which this app neither logs nor puts on a screen.
      note = subtitleMatchFailureNote;
    }
    if (!_stillOurs) return;
    // Two fetches take seconds, and the viewer can have changed the
    // subtitle in the meantime: a transform measured for a file that is
    // no longer on screen would ruin the one that replaced it, and its
    // score would be a claim about a file nobody measured.
    if (_externalSubtitle?.url != playing.url) {
      setState(() => _matchingSubtitle = false);
      return;
    }
    setState(() {
      _matchingSubtitle = false;
      _subtitleMatchNote = note;
    });
    if (match != null && match.convincing) {
      _adjustTiming(
        SubtitleTiming(
          calibratedSpeed: match.ratio,
          calibratedDelay: match.offset,
        ),
      );
    }
  }

  void _selectEmbeddedSubtitle(TrackInfo track) {
    _subtitlesChosenByHand = true;
    _tracks.value = _tracks.value.copyWith(activeSubtitleId: track.id);
    _resetSubtitleTiming();
    _engine?.setSubtitleTrack(track.id);
    _client?.dispatch(
      CoreActions.playerSubtitlePreferenceChanged(
        enabled: true,
        source: 'embedded',
        language: track.language,
      ),
    );
    // A track in the file has no release group and no URL that means
    // anything on the next episode; what is worth remembering is the
    // language, and that the file's own track was preferred to a
    // download.
    final language = track.language;
    if (language != null && language.trim().isNotEmpty) {
      _rememberPick(language: subtitleLanguageLabel(language), embedded: true);
    }
  }

  void _selectExternalSubtitle(SubtitleInfo subtitle) {
    _subtitlesChosenByHand = true;
    _subtitlePick = (
      url: subtitle.url.toString(),
      before: _tracks.value,
      beforeSubtitle: _externalSubtitle,
      auto: false,
    );
    _tracks.value = _tracks.value.copyWith(
      activeSubtitleId: subtitle.url.toString(),
    );
    _resetSubtitleTiming(subtitle);
    _addExternalSubtitle(subtitle);
    _client?.dispatch(
      CoreActions.playerSubtitlePreferenceChanged(
        enabled: true,
        source: 'external',
        language: subtitle.lang.isEmpty ? null : subtitle.lang,
      ),
    );
    // A file the addon gave no language for is a row reading `Unknown`,
    // which names nothing to look for next episode -- the same rule that
    // keeps an unnamed release group out of the timing memory.
    if (subtitle.lang.trim().isNotEmpty) {
      _rememberPick(
        language: subtitleLanguageLabel(subtitle.lang),
        releaseGroup: subtitle.releaseGroupKey,
      );
    }
  }

  void _disableSubtitles() {
    _subtitlesChosenByHand = true;
    _tracks.value = _tracks.value.copyWith(clearSubtitle: true);
    _resetSubtitleTiming();
    _engine?.disableSubtitles();
    _client?.dispatch(
      CoreActions.playerSubtitlePreferenceChanged(enabled: false),
    );
    _rememberPick();
  }

  /// Writes a pick by hand down against this show: the language and,
  /// where the addon named one, the release group of the very file, or --
  /// with no [language] -- that subtitles were turned off here on
  /// purpose.
  ///
  /// **Only the three handlers above call this.** The auto-pick applying
  /// what is remembered must never write, or one choice made in January
  /// becomes twenty-two counts by March and the two pinned languages can
  /// never change again. It is the discipline `_adjustTiming` keeps for
  /// `subtitleSync`, for the same reason: what is stored has to be a
  /// judgement, and a machine putting something back is not one.
  ///
  /// Nothing is remembered for a play with no meta behind it -- an
  /// offline file, a deep link straight to a stream -- because there is
  /// no show to key it on.
  void _rememberPick({
    String? language,
    String? releaseGroup,
    bool embedded = false,
  }) {
    final prefs = _prefs;
    final series = _syncSeries;
    if (prefs == null || series == null) return;
    prefs
        .setSubtitlePicks(
          prefs.subtitlePicks.remembering(
            language == null
                ? SubtitleShowPick.off(series: series)
                : SubtitleShowPick(
                    series: series,
                    language: language,
                    releaseGroup: releaseGroup,
                    embedded: embedded,
                  ),
          ),
        )
        .ignore();
  }

  /// What the auto-pick should look for, or null when nothing says.
  ///
  /// The session preference wins: it is what the viewer did a moment ago,
  /// on this very run, and the memory is what they did some other
  /// evening. It carries no release group -- the core's field has no
  /// room for one -- so the group only ever comes from the memory.
  ///
  /// The languages are compared as the *labels* the menu prints, since
  /// that is what a pick is remembered as; a code coming from the core
  /// goes through the same function to get there, so `sv` and `swe` are
  /// still one language on both paths.
  _WantedSubtitle? _wanted(PlayerState state) {
    final preference = state.subtitlePreference;
    if (preference != null) {
      final language = preference.language;
      return _WantedSubtitle(
        enabled: preference.enabled,
        language: language == null ? null : subtitleLanguageLabel(language),
        embeddedFirst: preference.source == 'embedded',
      );
    }
    final remembered = _prefs?.subtitlePicks.forSeries(_syncSeries);
    if (remembered == null) return null;
    return _WantedSubtitle(
      enabled: remembered.enabled,
      language: remembered.language,
      releaseGroup: remembered.releaseGroup,
      embeddedFirst: remembered.embedded,
    );
  }

  /// Applies the session's subtitle preference (set by an earlier pick in
  /// this Player session, e.g. the previous episode) to freshly opened
  /// media: off stays off; otherwise the first track in the preferred
  /// language, from the preferred source first. Waits for the engine to
  /// report the media loaded (see [_mediaLoaded]), then retries as
  /// tracks and addon results arrive until something matches, and counts
  /// as done only once the engine accepted the pick.
  ///
  /// With no session preference -- which is every fresh start, since the
  /// core clears it on `Unload` -- what this show was last watched with
  /// stands in ([_wanted]). The two are read the same way and differ in
  /// one thing: a remembered row can also name the release group of the
  /// file that was picked, and among the files of the right language one
  /// from that group is preferred.
  ///
  /// A show never watched is still left alone. Putting this viewer's
  /// commonest language on a programme nothing is known about would put
  /// subtitles on a film that needs none, and off is the honest floor;
  /// what the menu does for that case is lift the two languages they
  /// usually pick to the top of it.
  ///
  /// **Nothing here dispatches `SubtitlePreferenceChanged`.** The core's
  /// field means "the viewer said so, this session", and writing a
  /// remembered guess into it would make a memory indistinguishable from
  /// a judgement -- which is the distinction `_subtitlesChosenByHand`
  /// rests on -- as well as counting the guess as a pick next time the
  /// menu is opened.
  void _maybeAutoPickSubtitles() {
    if (_autoPickedSubtitles ||
        _autoPickingSubtitles ||
        _subtitlesChosenByHand ||
        !_mediaLoaded ||
        _opened == null ||
        _handedOver) {
      return;
    }
    final state = _state;
    if (state == null) return;
    final preference = _wanted(state);
    if (preference == null) return;
    final before = _tracks.value;
    // Where the multiplier has to go back to if the engine refuses the
    // pick below: the file playing now, if it is one of the addons'.
    // Putting the tracks back without this leaves the refused file's
    // multiplier on a subtitle that was in step.
    final beforeSubtitle = state.externalSubtitleSources
        .map((source) => source.subtitle)
        .where((subtitle) => subtitle.url.toString() == before.activeSubtitleId)
        .firstOrNull;
    final Future<void>? applied;
    if (!preference.enabled) {
      _tracks.value = before.copyWith(clearSubtitle: true);
      _resetSubtitleTiming();
      applied = _engine?.disableSubtitles();
    } else {
      final language = preference.language;
      bool matches(String? candidate) =>
          language == null ||
          (candidate != null &&
              subtitleLanguageLabel(candidate).toLowerCase() ==
                  language.toLowerCase());
      // The same list the menu is built from, in the same order. This is
      // the one path that applies a subtitle without the viewer looking,
      // so it is the one that has to take the language's best-known file
      // rather than whichever addon answered first.
      final offered = _offeredSubtitles(state.externalSubtitleSources);
      final candidates = offered
          .map((source) => source.subtitle)
          .where((s) => !_deadSubtitles.contains(s.url.toString()))
          .where((s) => matches(s.lang));
      // A remembered group is a preference among the files of the
      // language, never a condition on the language: a show that changes
      // release family between seasons, and the six files in ten that
      // name no group at all, both land on the head of the language the
      // way they would with nothing remembered.
      final group = preference.releaseGroup;
      final external =
          (group == null
              ? null
              : candidates
                    .where((s) => s.releaseGroupKey == group)
                    .firstOrNull) ??
          candidates.firstOrNull;
      final embedded = before.subtitle
          .where((t) => matches(t.language))
          .firstOrNull;
      final externalFirst = !preference.embeddedFirst;
      if (externalFirst && external != null ||
          embedded == null && external != null) {
        _tracks.value = before.copyWith(
          activeSubtitleId: external.url.toString(),
        );
        _resetSubtitleTiming(external);
        _subtitlePick = (
          url: external.url.toString(),
          before: before,
          beforeSubtitle: beforeSubtitle,
          auto: true,
        );
        applied = _addExternalSubtitle(external);
      } else if (embedded != null) {
        _tracks.value = before.copyWith(activeSubtitleId: embedded.id);
        _resetSubtitleTiming();
        applied = _engine?.setSubtitleTrack(embedded.id);
      } else {
        return;
      }
    }
    if (applied == null) return;
    final url = _opened;
    // What this pick put on screen, so the revert below can tell whether
    // it is still undoing its own work. `sub-add` fetches the URL under
    // mpv's `network-timeout`, so a refusal can land minutes after the
    // call, and by then the viewer may have chosen a file of their own.
    final applying = _tracks.value.activeSubtitleId;
    _autoPickingSubtitles = true;
    applied
        .then(
          (_) {
            if (_opened == url) _autoPickedSubtitles = true;
          },
          onError: (Object _) {
            // Rejected: show what is really selected and try again on the
            // next tracks/state change. An engine that refuses the call
            // itself; mpv refusing a file does not come this way
            // ([_onSubtitleFailed]).
            if (_opened != url ||
                !_stillOurs ||
                _tracks.value.activeSubtitleId != applying) {
              return;
            }
            _undoSubtitlePick(before, beforeSubtitle);
          },
        )
        .whenComplete(() => _autoPickingSubtitles = false);
  }

  // --- Subtitle timing by hand ---------------------------------------------

  /// Puts the timing panel up and the remote on it.
  ///
  /// Deliberately not part of the OSD: the bar fades on its three-second
  /// timer while this stays, because adjusting means pressing and then
  /// watching the picture for several seconds to see what the press did.
  /// It is drawn outside the fade and it is not on [_canAutoHide]'s list
  /// of things that stop it -- pinning the bar up over the very picture
  /// being judged would be the wrong half of the problem to solve. What
  /// makes that safe is that the panel is visible for as long as it holds
  /// focus, which is the rule [_hideControls] keeps for the bar.
  void _showSubtitleTiming() {
    if (_timingShown) return;
    setState(() => _timingShown = true);
    // After the frame that builds it: there is no node to focus until
    // the panel is in the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _timingShown) _timingFocus.requestFocus();
    });
  }

  /// Takes it away, and the remote back to the video with it -- a ring on
  /// a panel that is gone is focus the viewer can no longer see.
  ///
  /// The panel closing is what says the adjusting is over, so it is
  /// where what was pressed gets written down.
  void _hideSubtitleTiming() {
    if (!_timingShown) return;
    _flushRememberedTiming();
    final focused = _timingScope.hasFocus;
    setState(() => _timingShown = false);
    if (focused) _focusNode.requestFocus();
  }

  void _toggleSubtitleTiming() {
    if (_timingShown) {
      _hideSubtitleTiming();
    } else {
      _showSubtitleTiming();
    }
  }

  /// The addon files [state] offers, by language, as both subtitle sheets
  /// list them.
  List<SubtitleLanguageGroup> _subtitleGroups(PlayerState? state) =>
      groupSubtitlesByLanguage(
        // Ordered before grouping, so the numbering and "the first option
        // is what a tap applies" hold over the order the rows are actually
        // in.
        _offeredSubtitles(state?.externalSubtitleSources ?? const []),
        addonName: _subtitleAddonName,
        // The same name a shift is remembered against, so a row marked for
        // this release and a correction put back for it are talking about
        // the same file.
        release: _syncRelease,
      );

  Future<void> _openSubtitleMenu() async {
    var adjustTiming = false;
    await _showSheet(
      (context) => ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: _player!,
        builder: (context, json, _) {
          final state = _stateOf(json);
          final groups = _subtitleGroups(state);
          return ValueListenableBuilder<PlaybackTracks>(
            valueListenable: _tracks,
            builder: (context, tracks, _) => SubtitleMenu(
              embedded: tracks.subtitle,
              groups: groups,
              // The counts, and not which languages they lift: the menu
              // ranks what it draws, so its heading's note reports a
              // comparison over the whole sheet however this screen
              // assembles it (`SubtitleMenu.picks`).
              //
              // The pins are the menu's own presentation and are applied
              // after the ordering, not inside it: both consumers of the
              // list still get the same order, and the auto-pick's one
              // case that reads it (an enabled preference naming no
              // language takes the head of the whole list) is untouched.
              picks: _prefs?.subtitlePicks,
              activeId: tracks.activeSubtitleId,
              loading: state?.subtitlesLoading ?? false,
              onOff: () {
                _disableSubtitles();
                Navigator.of(context).pop();
              },
              onEmbedded: (track) {
                _selectEmbeddedSubtitle(track);
                Navigator.of(context).pop();
              },
              onExternal: (subtitle) {
                _selectExternalSubtitle(subtitle);
                Navigator.of(context).pop();
              },
              onAdjustTiming: () {
                adjustTiming = true;
                Navigator.of(context).pop();
              },
            ),
          );
        },
      ),
    );
    // Once the sheet is really gone, not from inside it: [_showSheet]
    // puts the remote back on the button that opened it as it closes,
    // which would take it straight off the panel again.
    if (adjustTiming && _stillOurs) _showSubtitleTiming();
  }
}
