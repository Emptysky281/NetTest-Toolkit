import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nettest/core/http.dart';
import 'package:nettest/core/proxy.dart';
import 'package:nettest/core/session.dart';
import 'package:nettest/core/util.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('black hole teardown: kernel or app?', (t) async {
    await t.runAsync(() async {
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final open = <Socket>[];
      srv.listen((c) {
        open.add(c);
        c.listen((d) {});
      });
      final u = parseUrl('http://127.0.0.1:${srv.port}/x');
      final ev = <Ev>[];
      // app-side idle timeout is 600s: anything breaking sooner is the OS
      final s = TcpSession(u.host, u.port, ProxyConfig(), ev.add, timeout: 600);
      await s.connect();
      debugPrint('connecting: state=${s.state}');
      s.expectResponse('GET', '/x');
      await s.send(
        Uint8List.fromList([
          for (final p in buildHttpRequest('GET', u.host, u.port, '/x')) ...p,
        ]),
      );
      s.shutdownWrite();
      final t0 = DateTime.now();
      for (var i = 0; i < 120; i++) {
        await Future.delayed(const Duration(seconds: 2));
        final el = DateTime.now().difference(t0);
        if (s.state != 'established') {
          debugPrint('BROKEN after ${el.inSeconds}s -> state=${s.state}');
          for (final e in ev.where(
            (e) => e.kind == 'close' || e.kind == 'err',
          )) {
            debugPrint('  ${e.kind} ${e.msg}');
          }
          break;
        }
        if (el.inSeconds % 30 < 2) {
          debugPrint('  still established after ${el.inSeconds}s');
        }
      }
      for (final c in open) {
        try {
          c.destroy();
        } catch (_) {}
      }
      await srv.close();
    });
  }, timeout: const Timeout(Duration(minutes: 6)));
}
