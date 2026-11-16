// Drives the real app UI: runs a single connection, a multi run and a TCP-step connect against a local
// mock server, then checks that each function page's log shows only its own entries and the 日志 page all.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nettest/main.dart';
import 'package:nettest/ui/app_state.dart';
import 'package:nettest/ui/widgets.dart';

import '../support/mock_servers.dart';

void main() {
  testWidgets('each page shows only its own connection log, the 日志 page shows all', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1180, 900)); // desktop layout (side rail)
    final mock = MockServers();
    await tester.runAsync(mock.start);
    final dir = Directory.systemTemp.createTempSync('nt_logroute');
    final st = AppState(settingsDir: dir.path);
    final url = 'http://127.0.0.1:${mock.httpPort}/echo';
    st.single.url = url;
    st.multi.url = url;
    st.step.url = url;
    st.settings
      ..saveOn = false
      ..bindOn = false;
    st.mCount = 2;
    st.mConc = 2;
    st.multi.keepAlive = false;
    await tester.pumpWidget(NetTestApp(st));

    // pump while real sockets work in the background
    Future<void> settle(int ms) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> go(String railLabel) async {
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text(railLabel)));
      await tester.pumpAndSettle();
    }

    // texts shown by the log view that is currently on screen
    List<String> visibleLog(LogSrc? src) {
      final view = find.byWidgetPredicate((w) => w is LogView && w.src == src);
      expect(view, findsOneWidget);
      return tester.widgetList<Text>(find.descendant(of: view, matching: find.byType(Text))).map((t) => t.data ?? '').toList();
    }

    await go('单连接');
    await tester.tap(find.text('建立连接并请求'));
    await settle(1500);

    await go('多连接');
    await tester.tap(find.text('开始'));
    await settle(2000);

    await go('分阶段');
    await tester.tap(find.text('① TCP 握手'));
    await settle(1500);

    bool has(List<String> lines, String s) => lines.any((l) => l.contains(s));
    // What each page's log view is showing. The list builds only the rows on screen (it auto-scrolls to the
    // end), so read the full list the view renders from, and check the view on screen is that same list.
    List<String> pageEntries(LogSrc? src) => [for (final l in st.logsFor(src)) l.e.msg];
    Future<List<String>> onScreen(String rail, LogSrc? src) async {
      await go(rail);
      final shown = visibleLog(src); // also asserts the right LogView is on screen
      final entries = pageEntries(src);
      expect(shown.where((t) => t.contains('[#') || t.contains('[--]')).every((t) => entries.any(t.contains)), isTrue,
          reason: 'every row on the $rail page belongs to that page');
      return entries;
    }

    final single = await onScreen('单连接', LogSrc.single);
    final multi = await onScreen('多连接', LogSrc.multi);
    final step = await onScreen('分阶段', LogSrc.step);
    final all = await onScreen('日志', null);
    // ignore: avoid_print
    print('single ${single.length} entries, multi ${multi.length}, step ${step.length}, all ${all.length}');

    expect(has(single, '单连接测试'), isTrue);
    expect(has(single, '多连接测试') || has(single, '批量完成：2 个连接'), isFalse, reason: 'no multi entries on 单连接');
    expect(has(multi, '多连接测试') && has(multi, '批量完成：2 个连接'), isTrue);
    expect(has(multi, '单连接测试'), isFalse, reason: 'no single entries on 多连接');
    expect(has(step, 'TCP 已建立'), isTrue);
    expect(has(step, '单连接测试') || has(step, '多连接测试'), isFalse, reason: 'no single/multi entries on 分阶段');
    expect(has(all, '单连接测试') && has(all, '多连接测试') && has(all, 'TCP 已建立'), isTrue, reason: '日志 page has everything');
    expect(all.length, single.length + multi.length + step.length, reason: 'every entry here came from a function page');

    st.stepSess?.close();
    await tester.runAsync(mock.stop);
    st.dispose();
    dir.deleteSync(recursive: true);
  });
}
