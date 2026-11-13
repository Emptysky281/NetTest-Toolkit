import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nettest/core/instance.dart';
import 'package:nettest/main.dart';
import 'package:nettest/ui/app_state.dart';

class _Launcher extends NamedInstanceLauncher {
  _Launcher() : super(storageRoot: Directory.systemTemp);
  Completer<InstanceLaunchResult> gate = Completer<InstanceLaunchResult>();
  final names = <String>[];
  final preferences = <Map<String, Object?>?>[];
  final histories = <List<String>>[];
  @override
  Future<InstanceLaunchResult> launch(
    String name, {
    Map<String, Object?>? preferences,
    List<String> urlHistory = const [],
  }) {
    names.add(name);
    this.preferences.add(preferences);
    histories.add(List.of(urlHistory));
    return gate.future;
  }

  void succeed() => gate.complete(
    InstanceLaunchResult(
      processName: names.last,
      processId: 4242,
      executablePath: 'C:/isolated/bundle/${names.last}',
      profileDirectory: 'C:/isolated/profile',
    ),
  );
}

Future<AppState> _mount(
  WidgetTester tester,
  _Launcher launcher, {
  bool child = false,
  Size size = const Size(1180, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final dir = Directory.systemTemp.createTempSync('nettest-instance-ui-');
  final state = AppState(
    settingsDir: dir.path,
    instanceLauncher: launcher,
    desktopInstance: DesktopInstance(
      executablePath: child ? 'C:/child/worker_B.exe' : 'C:/main/nettest.exe',
      processId: 101,
      profileDirectory: child ? 'C:/child/profile' : null,
    ),
  );
  state.settings
    ..bindOn = false
    ..saveOn = false;
  addTearDown(() {
    state.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  await tester.pumpWidget(NetTestApp(state));
  return state;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('多开'));
  await tester.pumpAndSettle();
}

ButtonStyleButton _button(WidgetTester tester, String text) =>
    tester.widget<ButtonStyleButton>(
      find
          .ancestor(
            of: find.text(text),
            matching: find.bySubtype<ButtonStyleButton>(),
          )
          .first,
    );

void _desktopTest(String name, WidgetTesterCallback body) => testWidgets(
  name,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.windows),
);

void main() {
  _desktopTest(
    'multi-instance dialog validates real process filenames before launching',
    (tester) async {
      final launcher = _Launcher();
      final st = await _mount(tester, launcher);
      try {
        await _open(tester);
        expect(find.text('自定义进程名多开'), findsOneWidget);
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('instance-process-name')),
              )
              .controller!
              .text,
          'nettest_2',
        );
        await tester.enterText(
          find.byKey(const ValueKey('instance-process-name')),
          '../outside',
        );
        await tester.tap(find.text('启动新实例'));
        await tester.pump();
        expect(find.textContaining('名称不能包含路径'), findsOneWidget);
        expect(launcher.names, isEmpty);
        await tester.enterText(
          find.byKey(const ValueKey('instance-process-name')),
          'CON',
        );
        await tester.tap(find.text('启动新实例'));
        await tester.pump();
        expect(find.textContaining('Windows 保留名称'), findsOneWidget);
        expect(launcher.names, isEmpty);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      } finally {
        st.dispose();
      }
    },
  );

  _desktopTest(
    'named launch shows preparation, prevents duplicates, and copies current options',
    (tester) async {
      final launcher = _Launcher();
      final st = await _mount(tester, launcher);
      try {
        st.single.url = 'https://parent.example/';
        st.history.add('https://history.example/');
        await _open(tester);
        await tester.enterText(
          find.byKey(const ValueKey('instance-process-name')),
          'probe_A',
        );
        await tester.tap(find.text('启动新实例'));
        await tester.pump();
        expect(st.launchingInstance, isTrue);
        expect(launcher.names, ['probe_A.exe']);
        expect(find.text('正在准备独立运行文件…'), findsOneWidget);
        expect(_button(tester, '启动新实例').onPressed, isNull);
        expect(_button(tester, '取消').onPressed, isNull);
        expect(
          launcher.preferences.single!['single'] as Map,
          containsPair('url', 'https://parent.example/'),
        );
        expect(launcher.histories.single, ['https://history.example/']);
        launcher.succeed();
        await tester.pumpAndSettle();
        expect(st.launchingInstance, isFalse);
        expect(find.text('自定义进程名多开'), findsNothing);
        expect(find.textContaining('已启动 probe_A.exe'), findsOneWidget);
        expect(st.single.url, 'https://parent.example/');
        await _open(tester);
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('instance-process-name')),
              )
              .controller!
              .text,
          'nettest_3',
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      } finally {
        st.dispose();
      }
    },
  );

  _desktopTest('turning off copy settings starts a fresh isolated profile', (
    tester,
  ) async {
    final launcher = _Launcher();
    final st = await _mount(tester, launcher);
    try {
      st.single.url = 'https://must-not-copy.example/';
      st.history.add('http://history.example/');
      await _open(tester);
      await tester.tap(find.text('复制当前设置与 URL 历史'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('instance-process-name')),
        'fresh_B.exe',
      );
      await tester.tap(find.text('启动新实例'));
      await tester.pump();
      expect(launcher.preferences.single, isNull);
      expect(launcher.histories.single, isEmpty);
      launcher.succeed();
      await tester.pumpAndSettle();
    } finally {
      st.dispose();
    }
  });

  _desktopTest(
    'failed startup remains actionable and does not leave launch busy',
    (tester) async {
      final launcher = _Launcher();
      final st = await _mount(tester, launcher);
      try {
        await _open(tester);
        await tester.tap(find.text('启动新实例'));
        await tester.pump();
        launcher.gate.completeError(
          const FileSystemException('permission denied'),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('无法启动新实例'), findsOneWidget);
        expect(st.launchingInstance, isFalse);
        expect(_button(tester, '启动新实例').onPressed, isNotNull);
        expect(_button(tester, '取消').onPressed, isNotNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      } finally {
        st.dispose();
      }
    },
  );

  _desktopTest('launch guard also prevents concurrent backend calls', (
    tester,
  ) async {
    final launcher = _Launcher();
    final st = await _mount(tester, launcher);
    try {
      final first = st.launchNamedInstance('first');
      await expectLater(st.launchNamedInstance('second'), throwsStateError);
      expect(launcher.names, ['first.exe']);
      launcher.succeed();
      await first;
      await tester.pump();
    } finally {
      st.dispose();
    }
  });

  _desktopTest(
    'named child shows its executable and PID and can open the launcher',
    (tester) async {
      final launcher = _Launcher();
      final st = await _mount(
        tester,
        launcher,
        child: true,
        size: const Size(900, 640),
      );
      try {
        expect(find.textContaining('worker_B.exe · PID 101'), findsOneWidget);
        expect(
          st.desktopInstance.windowTitle,
          'worker_B.exe - NetTest - 网络连接测试 [101]',
        );
        await _open(tester);
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('instance-process-name')),
              )
              .controller!
              .text,
          'worker_B_2',
        );
        expect(find.textContaining('详细信息'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        st.dispose();
      }
    },
  );
}
