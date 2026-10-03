import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/update/apk_installer.dart';

/// The Dart half of `xtremio/update`, against a stand-in for
/// `AppUpdateChannel.kt`: the words `InstallOutcome.name` sends are the
/// ones read here (the Kotlin side's own test pins its half).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) reply) {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformApkInstaller.channel, (call) async {
          calls.add(call);
          return reply(call);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PlatformApkInstaller.channel, null),
    );
  }

  test('install hands over the path and reads the outcome back', () async {
    answer(
      (_) => {
        'outcome': 'conflict',
        'message': 'INSTALL_FAILED_UPDATE_INCOMPATIBLE',
      },
    );
    final outcome = await const PlatformApkInstaller().install('/a/b.apk');
    expect(calls.single.method, 'install');
    expect(calls.single.arguments, {'path': '/a/b.apk'});
    expect(outcome.result, InstallResult.conflict);
    expect(outcome.message, 'INSTALL_FAILED_UPDATE_INCOMPATIBLE');
  });

  test('every word the Kotlin side sends has its own result', () async {
    for (final result in InstallResult.values) {
      answer((_) => {'outcome': result.name});
      expect(
        (await const PlatformApkInstaller().install('/x.apk')).result,
        result,
      );
    }
    answer((_) => {'outcome': 'something new'});
    expect(
      (await const PlatformApkInstaller().install('/x.apk')).result,
      InstallResult.failure,
    );
  });

  test('a refusal is a failure with its message', () async {
    answer(
      (_) => throw PlatformException(
        code: 'not_release',
        message: 'only the release app installs updates',
      ),
    );
    final outcome = await const PlatformApkInstaller().install('/x.apk');
    expect(outcome.result, InstallResult.failure);
    expect(outcome.message, 'only the release app installs updates');
  });

  test('the ABI and the permission are asked by name', () async {
    answer(
      (call) => switch (call.method) {
        'abi' => 'armeabi-v7a',
        'canRequestInstalls' => false,
        'openInstallPermission' => true,
        _ => null,
      },
    );
    const installer = PlatformApkInstaller();
    expect(await installer.primaryAbi(), 'armeabi-v7a');
    expect(await installer.canRequestInstalls(), isFalse);
    expect(await installer.openInstallPermission(), isTrue);
  });

  test('every failure says something of its own, with Android\'s words', () {
    final texts = {
      for (final result in InstallResult.values)
        if (result != InstallResult.success)
          result: installFailureText(InstallOutcome(result, 'WHY')),
    };
    expect(texts.values.toSet(), hasLength(texts.length));
    expect(texts[InstallResult.aborted], 'The update was not installed.');
    expect(
      texts[InstallResult.storage],
      'There is not enough space to install the update.',
    );
    for (final result in [
      InstallResult.conflict,
      InstallResult.incompatible,
      InstallResult.invalid,
      InstallResult.blocked,
      InstallResult.failure,
    ]) {
      expect(texts[result], contains('(WHY)'), reason: '$result');
    }
    expect(texts[InstallResult.blocked], contains('Play Protect'));
    expect(
      installFailureText(const InstallOutcome(InstallResult.failure)),
      'The install failed.',
    );
  });
}
