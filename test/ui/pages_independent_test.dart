// Drives the real UI: 单连接 and 多连接 run at the same time, each 停止 only stops its own page, and each
// page uses its own target URL.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nettest/main.dart';
import 'package:nettest/ui/app_state.dart';

import '../support/mock_servers.dart';

void main() {
  testWidgets('单连接 and 多连接 run independently, each with its own URL and 停止', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1180, 900));
    final mock = MockServers();
    await tester.runAsync(mock.start);
    final dir = Directory.systemTemp.createTempSync('nt_indep');
    final base = 'http://127.0.0.1:${mock.httpPort}';
    final st = AppState(settingsDir: dir.path);
    st.single.url = '$base/echo';
    st.multi.url = '$base/stall'; // sends 2 of 10 body bytes, then waits: 多连接 stays busy until 停止
    st.mCount = 2;
    st.mConc = 2;
    st.multi.keepAlive = false;
    st.settings
      ..saveOn = false
      ..bindOn = false;
    await tester.pumpWidget(NetTestApp(st));

    Future<void> settle(int ms) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> go(String railLabel) async {
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text(railLabel)));
      // a run in progress keeps the app-bar spinner animating, so pump a fixed time instead of pumpAndSettle
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    ButtonStyleButton button(String label) =>
        tester.widget<ButtonStyleButton>(find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>()).first);

    // each page shows its own URL in its own box
    await go('单连接');
    expect(find.text('$base/echo'), findsOneWidget);
    await go('多连接');
    expect(find.text('$base/stall'), findsOneWidget);

    // start 多连接 (long), then 单连接 while it is still running
    await tester.tap(find.text('开始'));
    await settle(400);
    expect(st.multiBusy, isTrue);
    await go('单连接');
    expect(button('建立连接并请求').onPressed, isNotNull, reason: '单连接 can start while 多连接 runs');
    await tester.tap(find.text('建立连接并请求'));
    await settle(800);
    expect(st.singleRunner!.sessions.single.ok, 1, reason: '单连接 finished its request during the 多连接 run');
    expect(st.singleRunner!.sessions.single.parser.done.single.path, '/echo', reason: '单连接 used its own URL');
    expect(st.multiBusy, isTrue, reason: '多连接 still running');
    expect(button('停止').onPressed, isNull, reason: '单连接 is idle again, so its 停止 is off');

    // 停止 on 多连接 stops only 多连接; a long 单连接 run is untouched
    st.single.url = '$base/stall';
    await tester.tap(find.text('建立连接并请求'));
    await settle(300);
    expect(st.singleBusy && st.multiBusy, isTrue, reason: 'both running at the same time');
    await go('多连接');
    await tester.tap(find.text('停止'));
    await settle(300);
    expect(st.multiBusy, isFalse, reason: '多连接 stopped');
    expect(st.singleBusy, isTrue, reason: '停止 on 多连接 does not stop 单连接');
    final multiPaths = {for (final s in st.multiRunner!.sessions) ...s.parser.done.map((r) => r.path)};
    expect(multiPaths.difference({'/stall'}), isEmpty, reason: '多连接 only requested its own URL');
    expect([st.multiRunner!.urlFor(1), st.multiRunner!.urlFor(2), st.singleRunner!.job.url], ['$base/stall', '$base/stall', '$base/stall']);
    await go('单连接');
    await tester.tap(find.text('停止'));
    await settle(300);
    expect(st.singleBusy, isFalse);

    // 停止 notes go to the page that was stopped
    final stoppedOn = [for (final s in LogSrc.values) if (st.logsFor(s).any((l) => l.e.msg == '已请求停止')) s];
    expect(stoppedOn, [LogSrc.single, LogSrc.multi]);
    // only 多连接 fills the result table
    expect(st.rows.keys.toSet(), {1, 2});

    await tester.runAsync(mock.stop);
    st.dispose();
    dir.deleteSync(recursive: true);
  });
}
