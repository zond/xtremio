/// Settings → Recommendations: the key and the model "More like this"
/// asks, and a way to find out whether that model can do the job.
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
/// typed a model name has no way of telling which of those they have. The
/// numbers, what they mean and why there are three of them are in
/// `check_model.dart`; this screen shows them and says what they mean on
/// the tile rather than in a help page nobody opens.
library;

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/tv_text_entry.dart';
import '../../widgets/tv_text_field.dart';
import '../similar/check_gemini.dart';
import '../similar/check_keys.dart';
import '../similar/check_model.dart';
import '../similar/similar_titles.dart';

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
  });

  final AppPrefs prefs;

  /// How the check is built, once there is a key to build it with. A test
  /// hands one that answers without a network; nothing else does.
  final ModelCheckFactory checkFor;

  static const Key apiKeyFieldKey = ValueKey('setting-similarApiKey');
  static const Key saveApiKeyKey = ValueKey('setting-similarApiKey-save');
  static const Key modelFieldKey = ValueKey('setting-similarModel');
  static const Key saveModelKey = ValueKey('setting-similarModel-save');
  static const Key testKey = ValueKey('setting-similar-test');

  /// What the section is headed with on the settings screen.
  static const String title = 'Recommendations';

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

  @override
  void initState() {
    super.initState();
    _apiKey.text = widget.prefs.similarApiKey ?? '';
    _model.text = widget.prefs.similarModel;
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

  /// A key changed is a check that no longer describes anything.
  Future<void> _saveApiKey() async {
    setState(() {
      _report = null;
      _failure = null;
      _running?.cancel();
      _running = null;
    });
    await widget.prefs.setSimilarApiKey(_apiKey.text);
    if (mounted) setState(() {});
  }

  Future<void> _saveModel() async {
    setState(() {
      _report = null;
      _failure = null;
      _running?.cancel();
      _running = null;
    });
    await widget.prefs.setSimilarModel(_model.text);
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
        const ListTile(
          leading: Icon(Icons.auto_awesome_outlined),
          title: Text('More like this'),
          subtitle: Text(
            'A row of suggestions under a title, from a model you hold the '
            'key to. With no key here the row does not appear and nothing '
            'is asked of anybody.',
          ),
        ),
        _field(
          fieldKey: RecommendationsSection.apiKeyFieldKey,
          saveKey: RecommendationsSection.saveApiKeyKey,
          controller: _apiKey,
          kind: TvTextKind.password,
          label: 'API key',
          // No hint text. The box is what is left of a phone's width once
          // the Save button has had its share, and a sentence in there is
          // a sentence laid out in 170 dp; what to paste is on the line
          // under the field, which has the whole width to say it in.
          hint: null,
          // Said here because it is what a viewer is deciding about when
          // they paste it, and because it is true: the key is stored on
          // this device, goes into one request, and is kept out of the
          // log and out of a copied diagnostics report.
          note:
              'Paste the key for your provider. It is kept on this device '
              'and sent only to that provider, and is never written to the '
              'log or to a diagnostics report.',
          onSave: _saveApiKey,
          onClear: () async {
            _apiKey.clear();
            await _saveApiKey();
          },
        ),
        _field(
          fieldKey: RecommendationsSection.modelFieldKey,
          saveKey: RecommendationsSection.saveModelKey,
          controller: _model,
          kind: TvTextKind.text,
          label: 'Model',
          hint: defaultSimilarModel,
          // Why the box exists at all: in one afternoon of measuring, two
          // of the models this might have defaulted to began answering
          // "404, no longer available to new users".
          note:
              'Emptied, it goes back to $defaultSimilarModel, which is what '
              'was measured. Model names rot; this is where the name of one '
              'that still answers goes.',
          onSave: _saveModel,
          onClear: () async {
            _model.clear();
            await _saveModel();
          },
        ),
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
          ListTile(
            leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
            title: const Text('No answer'),
            subtitle: Text(
              'The model did not answer: $failure. Nothing was measured.',
            ),
          ),
        if (report != null) ..._results(theme, report),
      ],
    );
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
          child: Text(note, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );

  /// The three numbers and the slowest call, each said on the tile that
  /// carries it. A number with nothing beside it is a number nobody can
  /// act on: chance is printed next to the judgement, the veto next to
  /// the inventions, and the row's budget next to the time.
  List<Widget> _results(ThemeData theme, ModelCheckReport report) => [
    ListTile(
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
    ListTile(
      leading: const Icon(Icons.balance_outlined),
      title: Text(
        'Judgement ${_score(report.judgement)} · '
        'chance is ${_score(toneChance)}',
      ),
      subtitle: const Text(
        'Handed a list of films, how often it puts the one that feels '
        'nearer the target first. The list is stocked with films that are '
        'closely related and feel nothing alike, so a model that sorts by '
        'relatedness scores below chance rather than above it.',
      ),
    ),
    ListTile(
      leading: const Icon(Icons.fact_check_outlined),
      title: Text('Agreement ${_score(report.agreement)}'),
      subtitle: const Text(
        'How much of what it recommended our answer keys rate. Anything '
        'outside the keys counts as nothing, so this is a floor and not a '
        'mark: a model can be right about a film nobody researched.',
      ),
    ),
    ListTile(
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
        'unusable whatever else it scored: an invented film does not leave '
        'a gap, it reaches the screen as a real poster for something that '
        'does not exist.',
      ),
    ),
    ListTile(
      leading: Icon(
        Icons.timer_outlined,
        color: report.tooSlow ? theme.colorScheme.error : null,
      ),
      title: Text('Slowest call ${_seconds(report.slowest)}'),
      subtitle: Text(
        report.tooSlow
            ? 'Over the ${_seconds(similarBudget)} the row lives under, so '
                  'expect no row.'
            : 'The row gives up at ${_seconds(similarBudget)}.',
      ),
    ),
  ];

  static String _score(double value) => value.toStringAsFixed(2);

  static String _seconds(Duration took) =>
      '${(took.inMilliseconds / 1000).toStringAsFixed(1)} s';
}
