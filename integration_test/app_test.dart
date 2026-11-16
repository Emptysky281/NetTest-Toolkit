import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/suite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('core features on device (incl. manual TLS)', (tester) async {
    final results = await tester.runAsync(() async {
      final dir = await testSaveDir();
      if (Directory(dir).existsSync()) Directory(dir).deleteSync(recursive: true);
      final s = Suite(dir, manualTls: true);
      await s.all();
      return s.results;
    });
    final bad = results!.where((c) => !c.ok).map((c) => '${c.name}: ${c.info}').toList();
    // ignore: avoid_print
    print('总计 ${results.length} 项，失败 ${bad.length}');
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));
  // UI was verified by driving the installed app with adb (tool/dev.ps1); widget-driven runs
  // crash the headless emulator's renderer on this machine.
}
