import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nettest/core/instance.dart';
import 'package:nettest/ui/app_state.dart';

class _Fixture {
  _Fixture(this.root, this.source, this.storage);
  final Directory root, source, storage;
  File get executable => File('${source.path}/nettest.exe');

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'nettest-named-instance-',
    );
    final source = await Directory('${root.path}/original').create();
    final storage = Directory('${root.path}/instances');
    for (final entry in <String, String>{
      'nettest.exe': 'current app executable',
      'flutter_windows.dll': 'engine',
      'libssl-3.dll': 'ssl',
      'libcrypto-3.dll': 'crypto',
      'dartjni.dll': 'jni',
      'native_assets.json': '{}',
      'data/app.so': 'application-v1',
      'data/icudtl.dat': 'icu',
      'data/flutter_assets/AssetManifest.bin': 'assets',
      'other.exe': 'do not copy',
      'downloads/private.txt': 'do not copy downloads',
      'old.zip': 'do not copy archive',
    }.entries) {
      final file = File('${source.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    final result = _Fixture(root, source, storage);
    addTearDown(() async {
      if (!await root.exists()) return;
      final resolved = await root.resolveSymbolicLinks();
      final temp = await Directory.systemTemp.resolveSymbolicLinks();
      expect(
        resolved.toLowerCase().startsWith(
          '${temp.toLowerCase()}${Platform.pathSeparator}nettest-named-instance-',
        ),
        isTrue,
      );
      await Directory(resolved).delete(recursive: true);
    });
    return result;
  }

  NamedInstanceLauncher launcher(InstanceProcessStarter start) =>
      NamedInstanceLauncher(
        storageRoot: storage,
        sourceExecutable: executable,
        startProcess: start,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'process names are validated as filenames, never shell commands or paths',
    () {
      for (final entry in {
        'nettest_A': 'nettest_A.exe',
        'nettest_B.EXE': 'nettest_B.exe',
        ' 测试进程一 ': '测试进程一.exe',
        'my app': 'my app.exe',
        'net-test.01': 'net-test.01.exe',
      }.entries) {
        expect(instanceExecutableName(entry.key), entry.value);
      }
      for (final bad in [
        '',
        '   ',
        '.',
        '..',
        '.exe',
        '..exe',
        '../escape',
        'a/b',
        'a\\b',
        'C:\\app',
        'a:b',
        'a|b',
        'a?b',
        'a*b',
        'a<b',
        'a>b',
        'a"b',
        'a\nb',
        'trailing.',
        'trailing. ',
        'trailing .exe',
        'CON',
        'NUL.txt',
        'COM1.exe',
        'LPT9',
        'com¹.exe',
      ]) {
        expect(
          () => instanceExecutableName(bad),
          throwsFormatException,
          reason: bad,
        );
      }
      expect(instanceExecutableName('a' * 64), '${'a' * 64}.exe');
      expect(() => instanceExecutableName('a' * 65), throwsFormatException);
    },
  );

  test(
    'normal executable has the main profile and a uniquely identified window',
    () async {
      final f = await _Fixture.create();
      final instance = DesktopInstance.load(
        executablePath: f.executable.path,
        processId: 101,
        windows: true,
      );
      expect(instance.isolated, isFalse);
      expect(instance.profileDirectory, isNull);
      expect(instance.processName, 'nettest.exe');
      expect(instance.windowTitle, 'NetTest - 网络连接测试 [101]');
    },
  );

  test(
    'named launch really creates the requested executable and complete runtime',
    () async {
      final f = await _Fixture.create();
      var starts = 0;
      final result = await f
          .launcher((exe, cwd) async {
            starts++;
            expect(File(exe).uri.pathSegments.last, 'probe_A.exe');
            expect(File(exe).parent.path, cwd);
            for (final runtime in [
              'flutter_windows.dll',
              'libssl-3.dll',
              'libcrypto-3.dll',
              'dartjni.dll',
              'native_assets.json',
              'data/app.so',
              'data/icudtl.dat',
              'data/flutter_assets/AssetManifest.bin',
            ]) {
              expect(
                File('$cwd/$runtime').existsSync(),
                isTrue,
                reason: runtime,
              );
            }
            expect(File('$cwd/other.exe').existsSync(), isFalse);
            expect(Directory('$cwd/downloads').existsSync(), isFalse);
            expect(File('$cwd/old.zip').existsSync(), isFalse);
            return 4242;
          })
          .launch('probe_A');
      expect(starts, 1);
      expect(result.processId, 4242);
      expect(result.processName, 'probe_A.exe');
      expect(
        File(result.executablePath).readAsStringSync(),
        'current app executable',
      );
      expect(f.executable.readAsStringSync(), 'current app executable');
    },
  );

  test('cloned settings, histories, downloads and local ports are independently seeded', () async {
    final f = await _Fixture.create();
    final preferences = <String, Object?>{
      'version': 2,
      'settings': {
        'proxy': {'mode': 'socks5', 'port': 1080},
        'saveDir': 'parent-downloads',
        'bindOn': true,
      },
      'single': {'url': 'https://single.example/path'},
      'payloadHistory': ['parent payload'],
    };
    final before = jsonEncode(preferences);
    final result = await f
        .launcher((_, _) async => 44)
        .launch(
          'probe_B.exe',
          preferences: preferences,
          urlHistory: ['https://one.example/', 'https://two.example/'],
        );
    final copied = jsonDecode(
      await File('${result.profileDirectory}/settings.json').readAsString(),
    ) as Map;
    expect(copied['single']['url'], 'https://single.example/path');
    expect(copied['settings']['proxy']['mode'], 'socks5');
    expect(copied['settings']['bindOn'], isFalse);
    expect(
      copied['settings']['saveDir'],
      '${result.profileDirectory}${Platform.pathSeparator}downloads',
    );
    expect(
      Directory(copied['settings']['saveDir'] as String).existsSync(),
      isTrue,
    );
    expect(
      jsonDecode(
        await File('${result.profileDirectory}/url_history.json')
            .readAsString(),
      ),
      ['https://one.example/', 'https://two.example/'],
    );
    expect(
      jsonEncode(preferences),
      before,
      reason: 'the parent settings must not be rewritten',
    );
  });

  test(
    'fresh instances do not inherit the parent options or URL history',
    () async {
      final f = await _Fixture.create();
      final result = await f.launcher((_, _) async => 45).launch('fresh');
      final prefs = jsonDecode(
        await File('${result.profileDirectory}/settings.json').readAsString(),
      ) as Map;
      expect(prefs['single'], isNull);
      expect(prefs['settings']['bindOn'], isFalse);
      expect(
        jsonDecode(
          await File('${result.profileDirectory}/url_history.json')
              .readAsString(),
        ),
        isEmpty,
      );
    },
  );

  test('reopening a created executable resolves its own stable profile without environment variables', () async {
    final f = await _Fixture.create();
    final result = await f.launcher((_, _) async => 46).launch('可自定义名称');
    final context = DesktopInstance.load(
      executablePath: result.executablePath,
      processId: 777,
      windows: true,
    );
    expect(context.isolated, isTrue);
    expect(context.profileDirectory, result.profileDirectory);
    expect(context.processName, '可自定义名称.exe');
    expect(context.windowTitle, '可自定义名称.exe - NetTest - 网络连接测试 [777]');
    expect(
      DesktopInstance.load(
        executablePath: result.executablePath,
        windows: false,
      ).profileDirectory,
      isNull,
    );
  });

  test(
    'marker files cannot redirect a process into arbitrary existing profiles',
    () async {
      final f = await _Fixture.create();
      final marker = File('${f.source.path}/${DesktopInstance.markerFileName}');
      for (final data in [
        <String, Object?>{'version': 1, 'profile': 'C:/user-existing-profile'},
        <String, Object?>{'version': 1, 'profile': '../../outside'},
        <String, Object?>{'version': 2, 'profile': '../profile'},
      ]) {
        await marker.writeAsString(jsonEncode(data));
        expect(
          () => DesktopInstance.load(
            executablePath: f.executable.path,
            windows: true,
          ),
          throwsFormatException,
        );
      }
      await marker.writeAsString('{broken');
      expect(
        () => DesktopInstance.load(
          executablePath: f.executable.path,
          windows: true,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'same-name launches still have different working directories and profiles',
    () async {
      final f = await _Fixture.create();
      final launcher = f.launcher((_, _) async => 50);
      final results = await Future.wait([
        launcher.launch('same_name'),
        launcher.launch('same_name'),
      ]);
      expect(results[0].processName, results[1].processName);
      expect(results[0].executablePath, isNot(results[1].executablePath));
      expect(results[0].profileDirectory, isNot(results[1].profileDirectory));
      await File('${results[0].profileDirectory}/only-first.txt')
          .writeAsString('first only');
      expect(
        File('${results[1].profileDirectory}/only-first.txt').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'later bundles are fresh copies and do not mutate running bundles',
    () async {
      final f = await _Fixture.create();
      final launcher = f.launcher((_, _) async => 51);
      final a = await launcher.launch('version_A');
      await File('${f.source.path}/data/app.so')
          .writeAsString('application-v2');
      final b = await launcher.launch('version_B');
      expect(
        File('${File(a.executablePath).parent.path}/data/app.so')
            .readAsStringSync(),
        'application-v1',
      );
      expect(
        File('${File(b.executablePath).parent.path}/data/app.so')
            .readAsStringSync(),
        'application-v2',
      );
    },
  );

  test(
    'invalid names or missing runtimes never invoke process start',
    () async {
      final f = await _Fixture.create();
      var starts = 0;
      final launcher = f.launcher((_, _) async {
        starts++;
        return 52;
      });
      await expectLater(launcher.launch('../invalid'), throwsFormatException);
      expect(f.storage.existsSync(), isFalse);
      await File('${f.source.path}/flutter_windows.dll').delete();
      await expectLater(
        launcher.launch('valid'),
        throwsA(isA<FileSystemException>()),
      );
      expect(starts, 0);
      expect(f.storage.existsSync(), isFalse);
    },
  );

  test(
    'failed start cleans only its own resolved workspace and keeps user files',
    () async {
      final f = await _Fixture.create();
      await f.storage.create();
      final keep = File('${f.storage.path}/keep.txt');
      await keep.writeAsString('do not remove');
      await expectLater(
        f
            .launcher((_, _) async {
              throw const ProcessException('fake', <String>[], 'failure');
            })
            .launch('failure'),
        throwsA(isA<ProcessException>()),
      );
      expect(keep.readAsStringSync(), 'do not remove');
      expect(f.storage.listSync().whereType<Directory>(), isEmpty);
      expect(f.executable.existsSync(), isTrue);
    },
  );

  test(
    'each seeded AppState restores and writes only its own persisted settings',
    () async {
      final f = await _Fixture.create();
      final launcher = f.launcher((_, _) async => 53);
      final a = await launcher.launch(
        'state_A',
        preferences: {
          'single': {'url': 'http://a.example/'},
        },
      );
      final b = await launcher.launch(
        'state_B',
        preferences: {
          'single': {'url': 'http://b.example/'},
        },
      );
      final one = AppState(settingsDir: a.profileDirectory),
          two = AppState(settingsDir: b.profileDirectory);
      addTearDown(() {
        one.dispose();
        two.dispose();
      });
      await one.loadPrefs();
      await two.loadPrefs();
      expect(one.single.url, 'http://a.example/');
      expect(two.single.url, 'http://b.example/');
      one.single.url = 'http://only-first.example/';
      one.savePrefs();
      await one.rememberUrl(one.single.url);
      final second = jsonDecode(
        await File('${b.profileDirectory}/settings.json').readAsString(),
      ) as Map;
      expect(second['single']['url'], 'http://b.example/');
      expect(
        jsonDecode(
          await File('${b.profileDirectory}/url_history.json').readAsString(),
        ),
        isEmpty,
      );
      await one.flushHistory();
      await two.flushHistory();
      one.dispose();
      two.dispose();
    },
  );
}
