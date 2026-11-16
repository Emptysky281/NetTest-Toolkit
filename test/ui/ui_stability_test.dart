import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nettest/core/runner.dart';
import 'package:nettest/main.dart';
import 'package:nettest/ui/app_state.dart';
import 'package:nettest/ui/run_pages.dart';
import 'package:nettest/ui/widgets.dart';

import '../support/mock_servers.dart';

Future<AppState> _mount(
  WidgetTester tester, {
  Size size = const Size(1180, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final dir = Directory.systemTemp.createTempSync('nettest-ui-fix-');
  final st = AppState(settingsDir: dir.path);
  st.settings
    ..bindOn = false
    ..saveOn = false;
  addTearDown(() {
    st.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  await tester.pumpWidget(NetTestApp(st));
  return st;
}

Future<void> _go(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text(label),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets(
    'target help states independent addresses, shared history, and shared outbound settings',
    (tester) async {
      final st = await _mount(tester);
      try {
        expect(
          find.textContaining('本页目标地址独立设置，不影响其他页面', skipOffstage: false),
          findsNWidgets(3),
        );
        expect(
          find.textContaining('右侧箭头可选共用 URL 历史', skipOffstage: false),
          findsNWidgets(3),
        );
        expect(
          find.textContaining('出站方式：direct（可在「设置」页修改）', skipOffstage: false),
          findsNWidgets(3),
        );
        final input = find.descendant(
          of: find.byType(SinglePage),
          matching: find.byType(UrlCombo),
        );
        await tester.enterText(
          find.descendant(of: input, matching: find.byType(TextField)),
          'https://single.example/x',
        );
        expect(st.single.url, 'https://single.example/x');
        expect(st.multi.url, isEmpty);
        expect(st.step.url, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        st.dispose();
        await tester.runAsync(
          () => st.flushHistory().timeout(const Duration(seconds: 2)),
        );
      }
    },
  );

  testWidgets(
    'step certificate UI follows global settings until explicitly overridden',
    (tester) async {
      final st = await _mount(tester);
      try {
        st.settings.verifyCerts = true;
        st.status.value++;
        await _go(tester, '分阶段');
        Finder checkbox() => find.descendant(
          of: find.widgetWithText(Check, '校验证书'),
          matching: find.byType(Checkbox),
        );
        expect(tester.widget<Checkbox>(checkbox()).value, isTrue);
        await tester.tap(find.text('校验证书'));
        await tester.pump();
        expect(st.step.verify, isFalse);
        await tester.tap(find.text('恢复跟随全局'));
        await tester.pump();
        expect(st.step.verify, isNull);
        expect(tester.widget<Checkbox>(checkbox()).value, isTrue);
        await _go(tester, '设置');
        await tester.ensureVisible(find.text('强制校验证书'));
        await tester.tap(find.text('强制校验证书'));
        await tester.pump();
        await _go(tester, '分阶段');
        expect(tester.widget<Checkbox>(checkbox()).value, isFalse);
        expect(st.step.verify, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        st.dispose();
        await tester.runAsync(
          () => st.flushHistory().timeout(const Duration(seconds: 2)),
        );
      }
    },
  );

  testWidgets(
    'multi backend rejects simultaneous starts as well as disabled buttons',
    (tester) async {
      final st = await _mount(tester);
      try {
        final mock = MockServers();
        await tester.runAsync(mock.start);
        addTearDown(() => tester.runAsync(mock.stop));
        st.multi
          ..url = 'http://127.0.0.1:${mock.httpPort}/echo'
          ..keepAlive = false;
        st.mCount = 2;
        st.mConc = 1;
        await _go(tester, '多连接');
        final context = tester.element(find.byType(MultiPage));
        final runners = <MultiRunner>{};
        st.status.addListener(() {
          if (st.multiRunner != null) runners.add(st.multiRunner!);
        });
        await tester.runAsync(() async {
          final first = st.runMulti(context);
          expect(st.multiBusy, isTrue);
          await Future.wait([first, st.runMulti(context)]);
          await st.multiRunner!.done;
        });
        await tester.pump();
        expect(runners, hasLength(1));
        expect(st.multiRunner!.summary!['fullOk'], 2);
        expect(tester.takeException(), isNull);
      } finally {
        st.dispose();
        await tester.runAsync(
          () => st.flushHistory().timeout(const Duration(seconds: 2)),
        );
      }
    },
  );

  testWidgets('updated two-line target hints fit the narrow layout', (
    tester,
  ) async {
    final st = await _mount(tester, size: const Size(390, 844));
    try {
      for (final label in ['多连接', '分阶段', '单连接']) {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.textContaining('本页目标地址独立设置，不影响其他页面'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    } finally {
      st.dispose();
      await tester.runAsync(
        () => st.flushHistory().timeout(const Duration(seconds: 2)),
      );
    }
  });
}
