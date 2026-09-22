/// Settings → Recommendations: the key and the model "More like this"
/// asks, and a way to find out whether that model can do the job.
///
/// **It says whose key it is.** These are Google AI Studio keys, made at
/// `aistudio.google.com` and spent against the Gemini API; a section that
/// says "API key" and "Model" invites somebody to paste an OpenAI or an
/// OpenRouter key and wait for it to work. The provider is named on the
/// field and on the line under it.
///
/// The app's own preferences and not `profile.settings` fields, for the
/// reason "Buffer ahead" and "Share while idle" are: they are this
/// device's, the file they live in is synced nowhere, and stremio-core's
/// `Settings` has no field for either. So this takes an [AppPrefs] rather
/// than a `SettingWriter` and renders whether or not the `ctx` field has
/// arrived.
///
/// **The key is auth material.** It is typed into an obscured field, it is
/// stored in the preferences file on this device, and the one place it
/// goes from there is the query string of its own provider's request. It
/// is never logged, never written to a diagnostics report, and never put
/// into an error this screen shows — a failure arrives as a
/// [SimilarTrouble], which is a handful of words with no URL in it. The
/// repository is public and its APKs are handed around; see
/// `AppPrefs.similarApiKeyKey`.
///
/// **The check is the reason this section is not two text fields.** The
/// models differ enormously — `tool/recommendations/README.md` has six
/// measured, one of which was below chance on both axes and invented
/// twenty titles in seventy-one — and a viewer who has pasted a key and
/// chosen a model name has no way of telling which of those they have. The
/// numbers, what they mean and why there are three of them are in
/// `check_model.dart`; this screen shows them and says what they mean on
/// the tile rather than in a help page nobody opens.
///
/// **The model is chosen from the account's own catalogue**
/// ([ModelCatalogue]) rather than typed, because the names rot and because
/// a television has no keyboard. What the chooser must not imply is that
/// everything in it works: 20 of 33 listed models failed when they were
/// actually asked something. So the list is where a model is *found* and
/// the check is where it is *settled*, and the tile says that in those
/// words. A model the list does not have — a fetch that failed, a name the
/// filter dropped, a viewer who knows better — stays chosen and stays
/// visible; a list that silently drops what somebody chose is a list that
/// overrides them.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/tv_text_entry.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/readout.dart';
import '../../widgets/tv_text_field.dart';
import '../similar/check_gemini.dart';
import '../similar/check_keys.dart';
import '../similar/check_model.dart';
import '../similar/model_catalogue.dart';
import '../similar/similar_titles.dart';
import 'core_settings.dart';

/// How a check is built once the key and the model are known.
///
/// A factory rather than a check, for the reason [MoreLikeThis]'s provider
/// is a factory: both arguments are preferences, and one built when the
/// screen was would be holding whatever was typed before.
typedef ModelCheckFactory = ModelCheck Function({
  required String apiKey,
  required String model,
});

/// What the app uses: Google's API, the model named in preferences.
ModelCheck _googleCheck({required String apiKey, required String model}) =>
    ModelCheck(
      provider: GeminiModelCheck(apiKey: apiKey, model: model),
    );

class RecommendationsSection extends StatefulWidget {
  const RecommendationsSection({
    super.key,
    required this.prefs,
    this.checkFor = _googleCheck,
    this.listModels = listGeminiModels,
  });

  final AppPrefs prefs;

  /// How the check is built, once there is a key to build it with. A test
  /// hands one that answers without a network; nothing else does.
  final ModelCheckFactory checkFor;

  /// Where the chooser's models come from. A test hands one that answers
  /// without a network; nothing else does.
  final ModelCatalogue listModels;

  static const Key apiKeyFieldKey = ValueKey('setting-similarApiKey');
  static const Key saveApiKeyKey = ValueKey('setting-similarApiKey-save');

  /// The chooser, keyed the way every other setting's menu on this screen
  /// is ([settingKey]).
  static final Key modelMenuKey = settingKey(AppPrefs.similarModelKey);

  /// The box the name goes in when there is no list to choose from. A key
  /// of its own rather than [modelMenuKey], because the two are different
  /// controls and only one of them is on screen at a time.
  static const Key modelFieldKey = ValueKey('setting-similarModel-typed');
  static const Key saveModelKey = ValueKey('setting-similarModel-save');
  static const Key testKey = ValueKey('setting-similar-test');

  /// What the section is headed with on the settings screen.
  static const String title = 'Recommendations';

  /// The provider, as the section names it. One name in one place: it is
  /// on the key's field, in its note and in the chooser's.
  static const String provider = 'Google AI Studio';

  /// How the measured default is marked in the chooser.
  static String label(String model) =>
      model == defaultSimilarModel ? '$model · measured' : model;

  @override
  State<RecommendationsSection> createState() => _RecommendationsSectionState();
}

class _RecommendationsSectionState extends State<RecommendationsSection> {
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _model = TextEditingController();

  /// The check in flight, or null. Held so that leaving the screen can
  /// stop it: it is six calls to somebody the viewer is paying.
  ModelCheck? _running;

  ModelCheckReport? _report;

  /// Why the model did not answer, in [SimilarTrouble]'s words. Never a
  /// provider's own message, which can quote the request back.
  String? _failure;

  /// The models the key can see, or null while there is no list: no key
  /// pasted, a listing in flight, or one that failed. Null is what puts
  /// the by-hand box on screen, so the three cases need not be told apart
  /// to answer "can this viewer still name a model".
  List<String>? _listed;

  /// The key a listing is out for, or null.
  ///
  /// The key rather than a flag, because a listing is answered long after
  /// it was asked for and the question it answers is "is this still the
  /// key we are waiting on" — a flag would have said only that *something*
  /// was in flight, which is the shape of bug where a value is read once
  /// and trusted later.
  String? _listingFor;

  bool get _listing => _listingFor != null;

  /// A listing was asked for and did not arrive. Kept apart from
  /// `_listed == null`, which is also what having no key looks like.
  bool _listFailed = false;

  @override
  void initState() {
    super.initState();
    _apiKey.text = widget.prefs.similarApiKey ?? '';
    _model.text = widget.prefs.similarModel;
    unawaited(_listModels());
  }

  @override
  void dispose() {
    // Leaving the screen cancels the check. Nothing further is asked and
    // whatever comes back is dropped.
    _running?.cancel();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  bool get _hasKey => widget.prefs.similarApiKey != null;

  /// A key changed is a check that no longer describes anything, and a
  /// list that was somebody else's account's.
  Future<void> _saveApiKey() async {
    setState(() {
      _report = null;
      _failure = null;
      _running?.cancel();
      _running = null;
      _listed = null;
      // Whatever is out is out for the old key, and is dropped when it
      // arrives rather than filling a menu with somebody else's account.
      _listingFor = null;
      _listFailed = false;
    });
    await widget.prefs.setSimilarApiKey(_apiKey.text);
    if (!mounted) return;
    setState(() {});
    await _listModels();
  }

  /// Asks the provider what this key can see.
  ///
  /// **With no key nothing is asked**, which is the rule the whole section
  /// is built on: there is no probe, no default key and no request until a
  /// viewer has pasted one of their own.
  ///
  /// Asked when the section is built and when Save is pressed, and from
  /// nowhere else: a rebuild is not another account to ask about. So a
  /// listing that failed needs no button of its own -- Save is the press
  /// that is already there, and pressing it is another go.
  Future<void> _listModels() async {
    final apiKey = widget.prefs.similarApiKey;
    if (apiKey == null || _listingFor == apiKey) return;
    setState(() {
      _listingFor = apiKey;
      _listFailed = false;
      _listed = null;
    });
    List<String>? listed;
    try {
      listed = await widget.listModels(apiKey);
    } on Object {
      // Whatever the provider said is neither shown nor kept: a message
      // from there can quote the request back, and the request carries
      // the key. What the screen says is that there is no list.
      listed = null;
    }
    // The key changed under it, or the screen is gone: a list fetched
    // with a key nobody is using is not this screen's answer, and a newer
    // listing is the one this screen is waiting on.
    if (!mounted || _listingFor != apiKey) return;
    setState(() {
      _listingFor = null;
      _listFailed = listed == null;
      _listed = listed;
    });
  }

  Future<void> _saveModel() => _setModel(_model.text);

  /// Writes which model is asked, from the chooser or from the box.
  Future<void> _setModel(String? value) async {
    setState(() {
      _report = null;
      _failure = null;
      _running?.cancel();
      _running = null;
    });
    await widget.prefs.setSimilarModel(value);
    // An emptied box is the default, and the box says so rather than
    // staying blank over a setting that is not blank.
    if (!mounted) return;
    setState(() => _model.text = widget.prefs.similarModel);
  }

  /// Six calls, a few seconds, and nothing blocking the interface: the
  /// screen stays walkable while it runs, and the press that leaves it
  /// cancels the rest.
  Future<void> _test() async {
    final apiKey = widget.prefs.similarApiKey;
    if (apiKey == null || _running != null) return;
    final check = widget.checkFor(
      apiKey: apiKey,
      model: widget.prefs.similarModel,
    );
    setState(() {
      _running = check;
      _report = null;
      _failure = null;
    });
    ModelCheckReport? report;
    String? failure;
    try {
      report = await check.run();
    } on SimilarTitlesFailure catch (trouble) {
      failure = trouble.trouble.describe;
    } on Object {
      // Anything else a provider threw. The type is not worth showing and
      // the message is not safe to: it can carry the request, and the
      // request carries the key.
      failure = 'the model could not be asked';
    }
    // Cancelled, or the screen is gone: neither a number nor a failure.
    if (!mounted || check != _running) return;
    setState(() {
      _running = null;
      _report = report;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = _running != null;
    final report = _report;
    final failure = _failure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Readout(
          child: ListTile(
            leading: Icon(Icons.auto_awesome_outlined),
            title: Text('More like this'),
            subtitle: Text(
              'A row of suggestions under a title, from a Google Gemini '
              'model asked with a key of your own. With no key here the row '
              'does not appear and nothing is asked of anybody.',
            ),
          ),
        ),
        _field(
          fieldKey: RecommendationsSection.apiKeyFieldKey,
          saveKey: RecommendationsSection.saveApiKeyKey,
          controller: _apiKey,
          kind: TvTextKind.password,
          // Two words, because the label is laid out in what is left of a
          // phone's width once the Save button has had its share — 171 dp
          // at 320 — and a label does not wrap. "Gemini key" is what will
          // fit that says whose it is; where one comes from is on the line
          // under the field, which has the whole width to say it in.
          label: 'Gemini key',
          // No hint text. The box is what is left of a phone's width once
          // the Save button has had its share, and a sentence in there is
          // a sentence laid out in 170 dp; what to paste is on the line
          // under the field, which has the whole width to say it in.
          hint: null,
          // Where a key comes from, said before anything else, because a
          // key from somewhere else is the mistake this section is most
          // likely to be handed: they all look alike and none of the
          // others answers here.
          //
          // Then what a viewer is deciding about when they paste it, and
          // it is true: the key is stored on this device, goes into the
          // provider's own requests, and is kept out of the log and out of
          // a copied diagnostics report.
          //
          // The site's name rather than its address: `aistudio.google.com`
          // is one nineteen-character word, no line under this field on a
          // 320 dp phone is wide enough to break it across, and the name
          // is the half somebody can search for anyway.
          note:
              'Made in ${RecommendationsSection.provider} and spent against '
              'the Gemini API. An OpenAI or OpenRouter key will not work '
              'here. It is kept on this device and sent only to Google, and '
              'is never written to the log or to a diagnostics report.',
          onSave: _saveApiKey,
          onClear: () async {
            _apiKey.clear();
            await _saveApiKey();
          },
        ),
        ..._modelChooser(theme),
        ListTile(
          key: RecommendationsSection.testKey,
          leading: const Icon(Icons.science_outlined),
          title: const Text('Test this model'),
          subtitle: Text(
            !_hasKey
                ? 'Paste an API key first.'
                : running
                ? 'Asking. Six calls against answer keys for three films; '
                      'leaving this screen stops it.'
                : 'Six calls against answer keys for three films — one '
                      'famous, two obscure — and a few seconds.',
          ),
          trailing: running
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
          enabled: _hasKey && !running,
          onTap: _hasKey && !running ? _test : null,
        ),
        if (failure != null)
          Readout(
            child: ListTile(
              leading: Icon(
                Icons.error_outline,
                color: theme.colorScheme.error,
              ),
              title: const Text('No answer'),
              subtitle: Text(
                'The model did not answer: $failure. Nothing was measured.',
              ),
            ),
          ),
        if (report != null) ..._results(theme, report),
      ],
    );
  }

  /// Which model is asked: a menu of what the key can see, the line under
  /// it saying what the menu is and is not, and — when there is no list —
  /// a box to name one in.
  ///
  /// A [SettingMenu] because that is what a choice between several values
  /// already is on this screen, and because a television can walk to one
  /// and press it: select opens a route listing every option with the
  /// current one focused, up and down walk them, select picks. A list
  /// nobody could reach with a D-pad would have replaced a box nobody can
  /// type into on a television with something no better.
  ///
  /// The menu is never empty and never shorter than the truth: with no
  /// list it still offers the measured default, and [SettingMenu] adds
  /// whatever is configured when the list does not have it.
  List<Widget> _modelChooser(ThemeData theme) {
    final listed = _listed;
    final configured = widget.prefs.similarModel;
    return [
      SettingTile(
        icon: Icons.smart_toy_outlined,
        title: 'Gemini model',
        subtitle: _listing
            ? 'Asking ${RecommendationsSection.provider} what this key can '
                  'use.'
            : listed == null
            ? _listFailed
                  ? 'The list could not be fetched. What is set here stands.'
                  : 'The measured default, until a key is pasted.'
            : listed.length == 1
            ? 'One model this key can see.'
            : '${listed.length} models this key can see.',
        menu: SettingMenu<String>(
          setting: AppPrefs.similarModelKey,
          value: configured,
          options: listed == null || listed.isEmpty
              ? [defaultSimilarModel]
              : listed,
          label: RecommendationsSection.label,
          onPicked: (model) => unawaited(_setModel(model)),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Readout(
          padding: const EdgeInsets.all(FocusRing.textInset),
          child: Text(
            // Both halves are measured and neither is obvious. The mark
            // says which model the evidence is about; the second sentence
            // says that the list is where a model is found and the check
            // is where it is settled.
            'The one marked measured is what the measuring settled on: the '
            'best coverage of the answer keys of anything that answers '
            'inside the five seconds the row waits. Being listed is not '
            'being usable — 20 of 33 listed models could not answer when '
            'they were asked something — so Test this model below is what '
            'settles it.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ),
      // No list, so a name can still go in by hand: a fetch that failed
      // must not lock a viewer out of a model we failed to list.
      if (listed == null && !_listing)
        _field(
          fieldKey: RecommendationsSection.modelFieldKey,
          saveKey: RecommendationsSection.saveModelKey,
          controller: _model,
          kind: TvTextKind.text,
          // One word, and it can afford fewer than the key's: a label over
          // a box with something in it floats up at three quarters size,
          // and the box under the chooser is 124 dp of a 320 dp phone.
          // The tile above it is what says which models these are.
          label: 'Model',
          hint: defaultSimilarModel,
          note: _listFailed
              ? 'The list could not be fetched, so the name goes in by '
                    'hand. Emptied, it goes back to $defaultSimilarModel.'
              : 'Until a key is pasted there is no list to choose from. '
                    'Emptied, it goes back to $defaultSimilarModel.',
          onSave: _saveModel,
          onClear: () async {
            _model.clear();
            await _saveModel();
          },
        ),
    ];
  }

  /// One labelled box with a Save beside it, and a line under it saying
  /// what typing there decides.
  ///
  /// A Save rather than a write on every keystroke: off a television a
  /// pasted key that is never submitted would otherwise be lost by
  /// walking away, and on one the value only arrives when the text-entry
  /// screen hands it back. [TvTextField] is why there is one field type
  /// in this app; a television cannot type into Flutter's own.
  Widget _field({
    required Key fieldKey,
    required Key saveKey,
    required TextEditingController controller,
    required TvTextKind kind,
    required String label,
    required String? hint,
    required String note,
    required Future<void> Function() onSave,
    required Future<void> Function() onClear,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TvTextField(
                key: fieldKey,
                controller: controller,
                kind: kind,
                decoration: InputDecoration(labelText: label, hintText: hint),
                onSubmitted: (_) => onSave(),
                onClear: onClear,
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(
              key: saveKey,
              onPressed: onSave,
              child: const Text('Save'),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          // What typing there decides is a paragraph, and a paragraph the
          // remote cannot reach is one it scrolls past: the note under the
          // key field is four lines of what the key is and where it goes.
          child: Readout(
            padding: const EdgeInsets.all(FocusRing.textInset),
            child: Text(note, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
      ],
    ),
  );

  /// The three numbers and the slowest call, each said on the tile that
  /// carries it. A number with nothing beside it is a number nobody can
  /// act on: chance is printed next to the judgement, the veto next to
  /// the inventions, and the row's budget next to the time.
  ///
  /// **Each is a [Readout].** This is the longest thing on the settings
  /// screen and the one somebody sits down to read, and on a television
  /// none of it took focus: the remote jumped from "Test this model"
  /// straight past the whole report, which therefore never scrolled into
  /// view. A row apiece rather than one ring round the five, because the
  /// D-pad walks this screen a row at a time everywhere else and each of
  /// these is one number with its own sentence under it.
  List<Widget> _results(ThemeData theme, ModelCheckReport report) => [
    Readout(
      child: ListTile(
        leading: Icon(
          report.usable
              ? Icons.check_circle_outline
              : Icons.report_problem_outlined,
          color: report.usable
              ? theme.colorScheme.primary
              : theme.colorScheme.error,
        ),
        title: Text(report.verdict),
        subtitle: Text(
          'Measured over ${report.targets} films and '
          '${report.suggested} suggestions.',
        ),
      ),
    ),
    Readout(
      child: ListTile(
        leading: const Icon(Icons.balance_outlined),
        title: Text(
          'Judgement ${_score(report.judgement)} · '
          'chance is ${_score(toneChance)}',
        ),
        subtitle: const Text(
          'Handed a list of films, how often it puts the one that feels '
          'nearer the target first. The list is stocked with films that '
          'are closely related and feel nothing alike, so a model that '
          'sorts by relatedness scores below chance rather than above it.',
        ),
      ),
    ),
    Readout(
      child: ListTile(
        leading: const Icon(Icons.fact_check_outlined),
        title: Text('Agreement ${_score(report.agreement)}'),
        subtitle: const Text(
          'How much of what it recommended our answer keys rate. Anything '
          'outside the keys counts as nothing, so this is a floor and not '
          'a mark: a model can be right about a film nobody researched.',
        ),
      ),
    ),
    Readout(
      child: ListTile(
        leading: Icon(
          Icons.movie_filter_outlined,
          color: report.inventsFilms ? theme.colorScheme.error : null,
        ),
        title: Text(
          report.invented == 0
              ? 'Invented films: none in ${report.suggested}'
              : 'Invented films: ${report.invented} in ${report.suggested}',
        ),
        subtitle: const Text(
          'Titles no catalogue has. More than one in six and the model is '
          'unusable whatever else it scored: an invented film does not '
          'leave a gap, it reaches the screen as a real poster for '
          'something that does not exist.',
        ),
      ),
    ),
    Readout(
      child: ListTile(
        leading: Icon(
          Icons.timer_outlined,
          color: report.tooSlow ? theme.colorScheme.error : null,
        ),
        title: Text('Slowest call ${_seconds(report.slowest)}'),
        subtitle: Text(
          report.tooSlow
              ? 'Over the ${_seconds(similarBudget)} the row lives under, '
                    'so expect no row.'
              : 'The row gives up at ${_seconds(similarBudget)}.',
        ),
      ),
    ),
  ];

  static String _score(double value) => value.toStringAsFixed(2);

  static String _seconds(Duration took) =>
      '${(took.inMilliseconds / 1000).toStringAsFixed(1)} s';
}
