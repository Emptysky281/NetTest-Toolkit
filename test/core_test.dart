import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nettest/core/platform.dart';
import 'package:nettest/testing/suite.dart';

void main() {
  test('core features (host)', () async {
    final dir = '${Directory.systemTemp.path}${Platform.pathSeparator}nettest_flutter_test';
    if (Directory(dir).existsSync()) Directory(dir).deleteSync(recursive: true);
    // Windows host: the manual TLS (OpenSSL) checks run too when windows/openssl is reachable,
    // e.g. NETTEST_OPENSSL_DIR=windows\openssl (Android runs them on the device instead).
    final s = Suite(dir, manualTls: Platform.isWindows && Native.manualTlsSupported);
    await s.all();
    final bad = s.results.where((c) => !c.ok).map((c) => '${c.name}: ${c.info}').toList();
    // ignore: avoid_print
    print('总计 ${s.results.length} 项，失败 ${bad.length}');
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
