import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nettest/core/platform.dart';
import 'package:nettest/core/proxy.dart';
import 'package:nettest/core/session.dart';
import 'package:nettest/ui/app_state.dart';

Future<Directory> _temp() async {
  final dir = await Directory.systemTemp.createTemp('nettest-download-fix-');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

Uint8List _request(String path) => Uint8List.fromList(
  latin1.encode('GET $path HTTP/1.1\r\nHost: localhost\r\n\r\n'),
);

Future<SecureServerSocket> _tlsServer() async {
  final context = SecurityContext()
    ..useCertificateChain('test/fixtures/localhost-cert.pem')
    ..usePrivateKey('test/fixtures/localhost-key.pem');
  final server = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    context,
  );
  final sockets = <Socket>[];
  server.listen(
    (socket) {
      sockets.add(socket);
      var replied = false;
      socket.listen((data) {
        if (replied) return;
        replied = true;
        socket.add(
          latin1.encode('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'),
        );
      }, onError: (Object _) {});
    },
    onError: (Object _) {},
  ); // expected strict-client rejection of this self-signed cert
  addTearDown(() async {
    for (final s in sockets) {
      s.destroy();
    }
    await server.close();
  });
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'concurrent same-name downloads use independent temp and final paths',
    () async {
      final dir = await _temp();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final headers = Completer<void>();
      var heads = 0;
      server.listen((c) {
        final index = sockets.length;
        sockets.add(c);
        var sent = false;
        c.listen((data) async {
          if (sent) return;
          sent = true;
          c.add(latin1.encode('HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n'));
          await c.flush();
          if (++heads == 2) headers.complete();
          await headers.future;
          await Future<void>.delayed(Duration(milliseconds: 100 + index * 80));
          c.add(latin1.encode(index == 0 ? 'AAA' : 'BBB'));
        }, onError: (Object _) {});
      });
      addTearDown(() async {
        for (final c in sockets) {
          c.destroy();
        }
        await server.close();
      });
      final ev = <Ev>[];
      final a = TcpSession('127.0.0.1', server.port, ProxyConfig(), ev.add)
        ..setSave(dir.path);
      final b = TcpSession('127.0.0.1', server.port, ProxyConfig(), ev.add)
        ..setSave(dir.path);
      addTearDown(() {
        a.close();
        b.close();
      });
      expect(await a.connect(), isTrue);
      expect(await b.connect(), isTrue);
      for (final s in [a, b]) {
        s.expectResponse('GET', '/same.bin');
        await s.send(_request('/same.bin'));
      }
      expect(
        await Future.wait([a.waitResponses(1, 2), b.waitResponses(1, 2)]),
        [true, true],
      );
      expect(a.parser.done.single.file, isNot(b.parser.done.single.file));
      expect(File(a.parser.done.single.file!).readAsStringSync(), 'AAA');
      expect(File(b.parser.done.single.file!).readAsStringSync(), 'BBB');
      expect(ev.where((e) => e.kind == 'err'), isEmpty);
      expect(
        dir.listSync().whereType<File>().where((f) => f.path.endsWith('.part')),
        isEmpty,
      );
    },
  );

  test(
    'asynchronous file open errors are handled immediately and only once',
    () async {
      final dir = await _temp();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      server.listen((c) {
        sockets.add(c);
        var sent = false;
        c.listen((data) async {
          if (sent) return;
          sent = true;
          c.add(latin1.encode('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n'));
          await c.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          c.add(latin1.encode('ok'));
        }, onError: (Object _) {});
      });
      addTearDown(() async {
        for (final c in sockets) {
          c.destroy();
        }
        await server.close();
      });
      final ev = <Ev>[];
      final uncaught = <Object>[];
      final completed = Completer<void>();
      final s = TcpSession('127.0.0.1', server.port, ProxyConfig(), ev.add)
        ..setSave(dir.path);
      addTearDown(s.close);
      await Directory('${dir.path}/blocked.bin.c${s.cid}_r1.part').create();
      runZonedGuarded(
        () async {
          try {
            expect(await s.connect(), isTrue);
            s.expectResponse('GET', '/blocked.bin');
            await s.send(_request('/blocked.bin'));
            await s.waitResponses(1, 2);
          } finally {
            completed.complete();
          }
        },
        (e, st) {
          uncaught.add(e);
        },
      );
      await completed.future.timeout(const Duration(seconds: 4));
      expect(uncaught, isEmpty);
      expect(s.saveErrors, 1);
      expect(ev.where((e) => e.msg.startsWith('保存失败')), hasLength(1));
      expect(s.parser.done.single.saveFailed, isTrue);
      expect(File('${dir.path}/blocked.bin').existsSync(), isFalse);
    },
  );

  test(
    'truncated responses still finish as .incomplete with no temporary files',
    () async {
      final dir = await _temp();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      server.listen((c) {
        sockets.add(c);
        c.listen((data) async {
          c.add(
            latin1.encode(
              'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort',
            ),
          );
          await c.flush();
          await c.close();
        }, onError: (Object _) {});
      });
      addTearDown(() async {
        for (final c in sockets) {
          c.destroy();
        }
        await server.close();
      });
      final s = TcpSession('127.0.0.1', server.port, ProxyConfig(), (_) {})
        ..setSave(dir.path);
      addTearDown(s.close);
      await s.connect();
      s.expectResponse('GET', '/cut.bin');
      await s.send(_request('/cut.bin'));
      expect(await s.waitResponses(1, 2), isFalse);
      await s.flushFiles();
      expect(
        File('${dir.path}/cut.bin.incomplete').readAsStringSync(),
        'short',
      );
      expect(
        dir.listSync().whereType<File>().where((f) => f.path.endsWith('.part')),
        isEmpty,
      );
    },
  );

  test(
    'local HTTPS accepts self-signed by default and rejects it in strict mode',
    () async {
      final server = await _tlsServer();
      for (final verify in [false, true]) {
        final s = TcpSession(
          '127.0.0.1',
          server.port,
          ProxyConfig(),
          (_) {},
          useTls: true,
          verifyCerts: verify,
          connectTimeout: 2,
        );
        addTearDown(s.close);
        expect(await s.connect(), !verify);
        if (!verify) {
          s.expectResponse('GET', '/');
          await s.send(_request('/'));
          expect(await s.waitResponses(1, 2), isTrue);
        } else {
          expect(s.error, contains('CERTIFICATE_VERIFY_FAILED'));
        }
      }
    },
  );

  test(
    'manual TLS actually honors inherited strictness and explicit bypass',
    () async {
      final server = await _tlsServer();
      final dir = await _temp();
      final st = AppState(settingsDir: dir.path);
      addTearDown(() async {
        st.dispose();
        await st.flushHistory();
      });
      st.settings.verifyCerts = true;
      for (final override in <bool?>[null, false]) {
        st.step.verify = override;
        final s = TcpSession(
          '127.0.0.1',
          server.port,
          ProxyConfig(),
          (_) {},
          connectTimeout: 2,
        );
        addTearDown(s.close);
        expect(await s.connect(), isTrue);
        await s.tlsBegin('localhost', verify: st.stepVerify, alpn: 'http/1.1');
        for (var i = 0; i < 40 && !s.tlsDone && !s.tlsFailed; i++) {
          await s.tlsSendNext();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(s.tlsDone, override == false);
        if (override == null) {
          expect(s.tlsFailed, isTrue);
          expect(s.lastTlsError, isNotNull);
        } else {
          s.expectResponse('GET', '/');
          await s.send(_request('/'));
          expect(await s.waitResponses(1, 2), isTrue);
        }
        s.close();
      }
    },
    skip: !Native.manualTlsSupported,
  );
}
