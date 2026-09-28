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

  /// Puts libmpv's subtitle multiplier and offset back to untouched (1.0 and
  /// 0.0) and records [subtitle] as the addon file they now belong to, or
  /// null when what is shown is not one.
  ///
  /// Every path that changes what is on screen calls this: mpv keeps
  /// `sub-speed` and `sub-delay` across a track change, so a timing left
  /// behind by the previous pick would ruin a subtitle that was correct.
  /// Nothing but the viewer moves either value away from untouched, so this
  /// is also the only thing that undoes their work.
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

  /// What the viewer is remembered to have fixed about [subtitle] here, and
  /// untouched when nothing is (every embedded track, subtitles off, and
  /// every file from an addon that names no release group).
  ///
  /// The speed is keyed on the series and the release group (what a file
  /// was timed against comes from where it came from), the offset on the
  /// video release as well (it is the video's pre-roll less what the
  /// subtitle's source assumed); see [SubtitleSyncMemory]. Both come back as
  /// measured halves of a [SubtitleTiming], so the next shift moves a tenth
  /// from where it was left.
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

  /// The multiplier [memory] holds for [releaseGroup]'s files of [series],
  /// and null when it holds none this build will put on a player.
  ///
  /// The range is checked here because this is where a stored number becomes
  /// `sub-speed`, and media_kit discards mpv's refusal of a value outside
  /// `0.1-10.0`: the previous file's multiplier would stay in force while
  /// the panel claimed a new one. A stored 1.0 is nothing applied.
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
  /// known ([castFilename]: the file the server says it opened, else the
  /// addon's claim), as a bare lower-case name.
  ///
  /// The whole filename rather than a parsed release group: two encodes by
  /// one group can start in different places, and a narrower key forgotten
  /// more often is the price of never being wrong.
  String? get _syncRelease {
    final name = castFilename(_state, serverFilename: _serverFilename);
    if (name == null) return null;
    final file = name.split(RegExp(r'[/\\]')).last.trim().toLowerCase();
    return file.isEmpty ? null : file;
  }

  /// [sources] in the order every consumer offers them: the menu, the
  /// reference picker, and the auto-pick that applies a file with nobody
  /// looking. One place, because a consumer that skipped it would apply
  /// whichever addon answered first.
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

  /// A press on the timing panel; the panel is rebuilt from [_timing], so it
  /// draws what mpv is really playing.
  ///
  /// It ends the auto-pick ([_subtitlesChosenByHand]): a viewer judging the
  /// subtitle in front of them has answered what the auto-pick guesses at.
  /// And it is the only path that remembers anything: every other change to
  /// the timing is the machine putting a file back ([_resetSubtitleTiming]),
  /// which is not a judgement. Reset on the panel is one, and comes through
  /// here.
  void _adjustTiming(SubtitleTiming timing) {
    if (timing == _timing) return;
    _subtitlesChosenByHand = true;
    setState(() => _timing = timing);
    _applySubtitleTiming();
    _rememberTiming();
  }

  /// The panel's Reset: back to untouched, and the marks with it.
  ///
  /// The marks are the viewer's work too: resetting the two numbers but
  /// keeping the points they came from would let the next mark rejoin a
  /// pair the viewer has just discarded. It goes through [_adjustTiming]
  /// like any press, so untouched is *forgotten* rather than stored as zero.
  void _undoSubtitleTiming() {
    _calibration = SubtitleCalibration.none;
    setState(() => _markNote = null);
    _adjustTiming(const SubtitleTiming());
  }

  /// A press of "This is right": the line on screen is where it belongs,
  /// which is one mark.
  ///
  /// The mark pairs the cue's raw time in the file
  /// ([PlaybackEngine.subtitleCueStart]) with the position that cue is
  /// *drawn* at under the transform just approved (`speed * cue + delay`),
  /// **never with the position the button was pressed at**: a cue is on
  /// screen for seconds, so the press instant is reaction time, which would
  /// push an in-step subtitle late and put seconds of error into a rate
  /// ([SubtitleCalibration.rateSpan] is sized for a tenth at each end).
  ///
  /// So one mark changes nothing; a second mark far off, after shifting the
  /// picture into place there, is what learns a rate (docs/ARCHITECTURE.md,
  /// "Marks"). The answer is dropped if the subtitle changed while the read
  /// was out.
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
  /// what a match is measured against. Without one nothing about matching
  /// is drawn: a control that cannot work claims a fix the app has not got.
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

  /// Measures [playing] against [reference] and applies the answer, or says
  /// why it did not.
  ///
  /// The score is shown either way, with the transform beside it, so a
  /// refusal (files for different episodes, a reference itself adrift) is
  /// something the viewer can judge. A convincing answer goes through
  /// [_adjustTiming]: the viewer chose the reference, so it is their
  /// judgement.
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

  /// Writes a pick by hand down against this show: the language and, where
  /// the addon named one, the file's release group -- or, with no
  /// [language], that subtitles were turned off here on purpose.
  ///
  /// **Only the three handlers above call this.** The auto-pick applying
  /// what is remembered must never write, or one choice would count again
  /// on every episode and the two pinned languages could never change: what
  /// is stored has to be a judgement. Nothing is remembered without a show
  /// to key it on (an offline file, a deep link straight to a stream).
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

  /// Starts the bounded wait of [_maybeAutoPickSubtitles] for a subtitle
  /// addon still answering, once per media. Every answer that lands runs
  /// the pick again on its own; this is only what ends the wait when one
  /// never does.
  void _waitForSubtitleAddons() {
    if (_subtitleWait != null) return;
    final url = _opened;
    _subtitleWait = Timer(PlayerScreen.subtitleWaitLimit, () {
      if (!mounted || _opened != url) return;
      _subtitleWaitOver = true;
      _maybeAutoPickSubtitles();
    });
  }

  /// Applies the session's subtitle preference to freshly opened media: off
  /// stays off; otherwise the first file or track in the preferred language,
  /// from the preferred source first. Waits for the media to load
  /// ([_mediaLoaded]), retries as tracks and addon results arrive, and
  /// counts as done only once the engine accepted the pick.
  ///
  /// With no session preference (every fresh start: the core clears it on
  /// `Unload`) what this show was last watched with stands in ([_wanted]),
  /// which can also prefer the release group of the file picked. A show
  /// never watched is left alone: off is the honest floor.
  ///
  /// **Nothing here dispatches `SubtitlePreferenceChanged`**: the core's
  /// field means "the viewer said so, this session", and a remembered guess
  /// in it would be indistinguishable from a judgement.
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
      final ofGroup = group == null
          ? null
          : candidates.where((s) => s.releaseGroupKey == group).firstOrNull;
      final external = ofGroup ?? candidates.firstOrNull;
      final embedded = before.subtitle
          .where((t) => matches(t.language))
          .firstOrNull;
      final externalFirst = !preference.embeddedFirst;
      // What was wanted is an addon's file -- the remembered release, or
      // any file of the language -- and it is not in yet. An addon that
      // has not answered may have it, and a pick made now is final for
      // this media: it would settle for another release, or for the
      // file's own track, just because that addon is slower than the
      // video. So hold off, until it answers or [PlayerScreen.subtitleWaitLimit] is up.
      final exact = group == null ? external : ofGroup;
      if (externalFirst &&
          exact == null &&
          !_subtitleWaitOver &&
          state.subtitles.any((addon) => addon.isLoading)) {
        _waitForSubtitleAddons();
        return;
      }
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
  /// Not part of the OSD: the bar fades on its timer while this stays,
  /// because adjusting means pressing and then watching the picture. It is
  /// drawn outside the fade and is not on [_canAutoHide]'s list; it is
  /// visible for as long as it holds focus, the rule [_hideControls] keeps
  /// for the bar.
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
              // The counts, not which languages they lift: the menu ranks
              // what it draws (`SubtitleMenu.picks`). The pins are the menu's
              // presentation, applied after the ordering, so every consumer
              // of the list still gets the same order.
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
