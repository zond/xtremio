import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'release_version.dart';

/// One file attached to a release.
@immutable
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    required this.digest,
  });

  /// The file name, which the release workflow keeps stable from release to
  /// release (`xtremio-arm64-v8a.apk`, ...): what an asset is chosen by.
  final String name;

  /// `browser_download_url`: GitHub redirects it to the bytes.
  final Uri url;

  /// The size in bytes GitHub reports, 0 when it reports none.
  final int size;

  /// GitHub's `sha256:<hex>` of the file, null on an asset it has none for.
  final String? digest;
}

/// A published release: what `releases/latest` answers.
@immutable
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.notes,
    required this.page,
    required this.assets,
  });

  /// The tag as pushed, `v0.1.14`. What "Skip this version" remembers.
  final String tag;

  final ReleaseVersion version;

  /// The release body, as the release procedure writes it (Markdown).
  final String notes;

  /// The release's page on GitHub, for a build that cannot install.
  final Uri page;

  final List<ReleaseAsset> assets;

  /// What `GET /repos/zond/xtremio/releases/latest` answered, or a
  /// [FormatException] when it is not a release this app can read -- a tag
  /// that is not a version is one, and so is a draft or a pre-release (the
  /// endpoint excludes both, and this says so if that ever changes).
  factory ReleaseInfo.fromGitHub(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('the release is not an object');
    }
    if (json['draft'] == true || json['prerelease'] == true) {
      throw const FormatException('the latest release is not published');
    }
    final tag = json['tag_name'];
    final version = tag is String ? ReleaseVersion.parse(tag) : null;
    if (tag is! String || version == null || !version.isRelease) {
      throw FormatException('the latest release tag is not a version: $tag');
    }
    final page = Uri.tryParse(json['html_url'] as String? ?? '');
    return ReleaseInfo(
      tag: tag,
      version: version,
      notes: json['body'] as String? ?? '',
      page: page ?? Uri.parse(releasesPage),
      assets: [
        for (final asset in json['assets'] as List? ?? const [])
          if (asset case {
            'name': final String name,
            'browser_download_url': final String url,
          })
            ReleaseAsset(
              name: name,
              url: Uri.parse(url),
              size: asset['size'] is int ? asset['size'] as int : 0,
              digest: asset['digest'] as String?,
            ),
      ],
    );
  }

  /// The asset called [name], or null.
  ReleaseAsset? asset(String name) {
    for (final asset in assets) {
      if (asset.name == name) return asset;
    }
    return null;
  }

  /// Where every release is listed.
  static const String releasesPage = 'https://github.com/zond/xtremio/releases';
}

/// The APK built for a device whose first ABI is [abi]
/// (`Build.SUPPORTED_ABIS[0]`), null for an ABI the release builds none
/// for.
///
/// The first ABI, because that is the one the device prefers and runs the
/// app as: a phone with `arm64-v8a` first gets the 64-bit build, and a
/// Chromecast with Google TV -- a 64-bit chip with a 32-bit userspace, whose
/// list is `armeabi-v7a,armeabi` -- gets the 32-bit one, which is the only
/// one it can install.
String? apkAssetNameForAbi(String abi) => switch (abi) {
  'arm64-v8a' => 'xtremio-arm64-v8a.apk',
  'armeabi-v7a' => 'xtremio-armeabi-v7a.apk',
  _ => null,
};

/// [markdown] as text a dialog can show: headings, emphasis, inline code
/// marks and HTML comments gone, links reduced to their words, list
/// markers drawn as bullets, and no run of more than one blank line.
///
/// Not a Markdown renderer: release notes are a few headings and lists,
/// and this is what makes them read as prose rather than as source.
String releaseNotesText(String markdown) {
  var text = markdown.replaceAll('\r\n', '\n');
  text = text.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  // Images go entirely; links keep their words.
  text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  text = text.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!);
  final lines = <String>[];
  for (final raw in text.split('\n')) {
    var line = raw.trimRight();
    line = line.replaceFirst(RegExp(r'^\s{0,3}#{1,6}\s+'), '');
    line = line.replaceFirstMapped(
      RegExp(r'^(\s*)[-*+]\s+'),
      (m) => '${m[1]}• ',
    );
    line = line
        .replaceAll(RegExp(r'\*\*|__'), '')
        .replaceAll(RegExp(r'(?<![\w*])[*_](?=\S)|(?<=\S)[*_](?![\w*])'), '')
        .replaceAll('`', '');
    if (line.isEmpty && (lines.isEmpty || lines.last.isEmpty)) continue;
    lines.add(line);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}

/// Where the latest release comes from. An interface so tests hand over a
/// release instead of asking GitHub.
abstract interface class ReleaseSource {
  /// The latest published release. Throws when it cannot be had: offline,
  /// rate limited, an answer that is not a release.
  Future<ReleaseInfo> latest();
}

/// [ReleaseSource] over GitHub's REST API, unauthenticated.
///
/// Unauthenticated means 60 requests an hour per IP address, shared with
/// everything else on the network asking GitHub anything -- and a
/// conditional request still counts. Which is why nothing here is polled:
/// `AppUpdates` asks at most once a day by itself.
class GitHubReleaseSource implements ReleaseSource {
  GitHubReleaseSource({
    Uri? endpoint,
    this.timeout = const Duration(seconds: 20),
  }) : endpoint = endpoint ?? latestEndpoint;

  static final Uri latestEndpoint = Uri.parse(
    'https://api.github.com/repos/zond/xtremio/releases/latest',
  );

  final Uri endpoint;
  final Duration timeout;

  @override
  Future<ReleaseInfo> latest() async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(endpoint).timeout(timeout);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set('X-GitHub-Api-Version', '2022-11-28')
        ..set(HttpHeaders.userAgentHeader, 'xtremio');
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          response.statusCode == HttpStatus.forbidden ||
                  response.statusCode == HttpStatus.tooManyRequests
              ? 'GitHub is rate limiting this network; try again later'
              : 'GitHub answered ${response.statusCode}',
          uri: endpoint,
        );
      }
      return ReleaseInfo.fromGitHub(jsonDecode(body));
    } finally {
      client.close(force: true);
    }
  }
}
