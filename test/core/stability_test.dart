import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nettest/core/proxy.dart';
import 'package:nettest/core/runner.dart';
import 'package:nettest/core/session.dart';
import 'package:nettest/core/util.dart';
import 'package:nettest/ui/app_state.dart';

class _Peer {
  _Peer(this.server);
  final ServerSocket server;
  final sockets = <Socket>[];
  final wire = <List<int>>[];
  String get url => 'http://127.0.0.1:${server.port}/audit.bin';
  static Future<_Peer> start({
    bool respond = true,
    FutureOr<void> Function(Socket socket, int index)? reply,
  }) async {
    final peer = _Peer(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    peer.server.listen((socket) {
      final index = peer.sockets.length;
      peer.sockets.add(socket);
      final bytes = <int>[];
      peer.wire.add(bytes);
      var answered = false;
      socket.listen((data) async {
        bytes.addAll(data);
        if (!respond ||
            answered ||
            !latin1.decode(bytes).contains('\r\n\r\n')) {
          return;
        }
        answered = true;
        if (reply != null) {
          await reply(socket, index);
        } else {
          socket.add(
            latin1.encode('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'),
          );
        }
      }, onError: (Object _) {});
    });
    addTearDown(peer.close);
    return peer;
  }

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

Future<void> _until(
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final timer = Stopwatch()..start();
  while (!ready()) {
    if (timer.elapsed > timeout) {
      fail('condition did not complete within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<Directory> _temp(String name) async {
  final dir = await Directory.systemTemp.createTemp('nettest-fix-$name-');
  addTearDown(() async {
    // This is exactly the directory created above, never a computed parent.
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

Future<AppState> _state({bool save = false}) async {
  final dir = await _temp('state');
  final state = AppState(settingsDir: dir.path);
  state.settings
    ..bindOn = false
    ..saveOn = save;
  addTearDown(() async {
    state.dispose();
    await state.flushHistory();
  });
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cancel before DNS/open prevents a late connection, even with no timeout',
    () async {
      final peer = await _Peer.start();
      final s = TcpSession(
        '127.0.0.1',
        peer.server.port,
        ProxyConfig(),
        (_) {},
        connectTimeout: 0,
      );
      final connecting = s.connect();
      s.close();
      expect(await connecting.timeout(const Duration(seconds: 1)), isFalse);
      expect(s.state, 'closed');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(peer.sockets, isEmpty);
    },
  );

  test('cancel interrupts a stalled proxy handshake with no timeout', () async {
    final peer = await _Peer.start(respond: false);
    final s = TcpSession(
      'target.invalid',
      80,
      ProxyConfig(mode: 'socks5', host: '127.0.0.1', port: peer.server.port),
      (_) {},
      connectTimeout: 0,
    );
    addTearDown(s.close);
    final connecting = s.connect();
    await _until(() => peer.wire.any((bytes) => bytes.isNotEmpty));
    s.close();
    expect(await connecting.timeout(const Duration(seconds: 1)), isFalse);
    expect(s.state, 'closed');
  });

  test(
    'DNS tries a working IPv4 candidate after localhost IPv6 fails',
    () async {
      final peer = await _Peer.start();
      final s = TcpSession(
        'localhost',
        peer.server.port,
        ProxyConfig(),
        (_) {},
        connectTimeout: 1,
      );
      addTearDown(s.close);
      expect(await s.connect(), isTrue);
      expect(s.sock!.remoteAddress.type, InternetAddressType.IPv4);
      expect(s.stats, contains('dns'));
    },
  );

  test(
    'session and runner proxy configurations are immutable snapshots',
    () async {
      final peer = await _Peer.start();
      final proxy = ProxyConfig();
      final s = TcpSession('127.0.0.1', peer.server.port, proxy, (_) {});
      final r = MultiRunner(
        HttpJob(peer.url, keepAlive: false),
        proxy,
        (_) {},
        count: 2,
        concurrency: 1,
      );
      addTearDown(() {
        s.close();
        r.cancel();
      });
      proxy
        ..mode = 'http'
        ..port = 1;
      expect(s.proxy.mode, 'direct');
      expect(await s.connect(), isTrue);
      r.start();
      await r.done;
      expect(r.summary!['fullOk'], 2);
    },
  );

  test(
    'hold is once and does not block the next request slot or transfer timing',
    () async {
      final peer = await _Peer.start();
      final r = MultiRunner(
        HttpJob(peer.url, hold: 0.8),
        ProxyConfig(),
        (_) {},
        count: 2,
        concurrency: 1,
      );
      addTearDown(r.cancel);
      r.start();
      await _until(
        () => r.sessions.length == 2 && r.sessions.every((s) => s.ok == 1),
        timeout: const Duration(milliseconds: 650),
      );
      expect(r.sessions.every((s) => s.holding), isTrue);
      for (final s in r.sessions) {
        expect(s.tRequestsDone - s.tLastRx!, lessThan(0.3));
      }
      await r.done;
      final first = r.sessions.first;
      final postResponse =
          first.stats['duration']! - (first.tLastRx! - first.t0);
      expect(postResponse, inInclusiveRange(0.7, 1.4));
    },
  );

  test(
    'invalid URL produces a failure row and stays in the batch denominator',
    () async {
      final peer = await _Peer.start();
      final events = <Ev>[];
      final r = MultiRunner(
        HttpJob(peer.url, keepAlive: false),
        ProxyConfig(),
        events.add,
        count: 2,
        urls: ['http://[', peer.url],
      );
      addTearDown(r.cancel);
      r.start();
      await r.done;
      expect(r.summary!['total'], 2);
      expect(r.summary!['fullOk'], 1);
      expect(r.summary!['errors'] as Map, hasLength(1));
      final rows = <int, RowData>{};
      for (final e in events.where((e) => e.kind == 'row')) {
        final row = e.data as RowData;
        rows[row.idx] = row;
      }
      expect(rows.keys.toSet(), {1, 2});
      expect(rows[1]!.status, '失败');
      expect(rows[1]!.error, isNotEmpty);
    },
  );

  test('URL validation rejects unsupported schemes, missing hosts and invalid ports', () {
    for (final url in [
      '',
      'http://',
      'ftp://example.com/file',
      'http://x:0/',
      'http://x:65536/',
      'http://[',
    ]) {
      expect(() => parseUrl(url), throwsFormatException, reason: url);
    }
    expect(parseUrl(' localhost:8080/x?q=1 ').path, '/x?q=1');
    expect(parseUrl('https://[::1]/').host, '::1');
  });

  test('single startup is locked before its first await', () async {
    final peer = await _Peer.start();
    final st = await _state();
    st.single
      ..url = peer.url
      ..hold = 0.25;
    final runners = <MultiRunner>{};
    st.status.addListener(() {
      if (st.singleRunner != null) runners.add(st.singleRunner!);
    });
    final first = st.runSingle();
    expect(st.singleBusy, isTrue);
    await Future.wait([first, st.runSingle()]);
    await st.singleRunner!.done;
    expect(runners, hasLength(1));
    expect(peer.sockets, hasLength(1));
  });

  test(
    'stop during preparation invalidates startup without sending a SYN',
    () async {
      final peer = await _Peer.start();
      final st = await _state();
      st.single.url = peer.url;
      final starting = st.runSingle();
      st.stop(LogSrc.single);
      await starting;
      expect(st.singleBusy, isFalse);
      expect(st.singleRunner, isNull);
      expect(peer.sockets, isEmpty);
      await st.runSingle();
      await st.singleRunner!.done;
      expect(st.singleRunner!.sessions.single.ok, 1);
    },
  );

  test('TCP-only on HTTPS sends no TLS ClientHello or HTTP payload', () async {
    final peer = await _Peer.start(respond: false);
    final st = await _state();
    st.single
      ..url = peer.url.replaceFirst('http:', 'https:')
      ..hold = 0.15;
    await st.runSingle(connectOnly: true);
    await st.singleRunner!.done;
    expect(st.singleRunner!.sessions.single.useTls, isFalse);
    expect(st.singleRunner!.sessions.single.stats, contains('tcp'));
    expect(peer.wire.expand((bytes) => bytes), isEmpty);
  });

  test('invalid single and step addresses are rejected without throwing or starting', () async {
    final st = await _state();
    st.single.url = 'http://[';
    st.step.url = 'ftp://example.com/file';
    await st.runSingle();
    await st.stepConnect();
    expect(st.singleRunner, isNull);
    expect(st.stepSess, isNull);
    expect(st.busy, isFalse);
  });

  test('repeated step connect has one owner and closing it closes the only session', () async {
    final peer = await _Peer.start();
    final st = await _state();
    st.step.url = peer.url;
    await Future.wait([st.stepConnect(), st.stepConnect()]);
    await _until(() => peer.sockets.isNotEmpty);
    expect(peer.sockets, hasLength(1));
    expect(st.stepSess!.state, 'established');
    st.stepClose('fin');
    expect(st.stepSess!.state, 'closed');
  });

  test('step close cancels startup before a socket exists', () async {
    final peer = await _Peer.start();
    final st = await _state();
    st.step.url = peer.url;
    final connecting = st.stepConnect();
    st.stepClose('fin');
    await connecting;
    expect(st.stepSess!.state, 'closed');
    expect(st.stepBusy, isFalse);
    expect(peer.sockets, isEmpty);
  });

  test(
    'step fragment sending cannot be interleaved with a replacement connection',
    () async {
      final peer = await _Peer.start();
      final st = await _state();
      st.step
        ..url = peer.url
        ..chunk = 1
        ..chunkDelay = 0.2;
      await st.stepConnect();
      final first = st.stepSess;
      final sending = st.stepChunked();
      expect(st.stepBusy, isTrue);
      await st.stepConnect();
      expect(st.stepSess, same(first));
      st.stepClose('fin');
      await sending.timeout(const Duration(seconds: 1));
      expect(st.stepBusy, isFalse);
      expect(first!.state, 'closed');
    },
  );

  test(
    'clearing URL history keeps later persistence and restart restore working',
    () async {
      final st = await _state();
      await st.rememberUrl('http://before.invalid/');
      await st.clearHistory();
      await st.rememberUrl('http://after.invalid/');
      final file = File('${st.settings.saveDir}/url_history.json');
      expect(jsonDecode(await file.readAsString()), ['http://after.invalid/']);
      final restored = AppState(settingsDir: st.settings.saveDir);
      addTearDown(() async {
        restored.dispose();
        await restored.flushHistory();
      });
      await restored.flushHistory();
      expect(restored.history, ['http://after.invalid/']);
    },
  );

  test(
    'concurrent URL updates and clear serialize valid atomic snapshots',
    () async {
      final st = await _state();
      await Future.wait([
        for (var i = 0; i < 25; i++) st.rememberUrl('http://host$i.invalid/'),
      ]);
      final file = File('${st.settings.saveDir}/url_history.json');
      expect(st.history, hasLength(20));
      expect(jsonDecode(await file.readAsString()), st.history);
      await Future.wait([
        st.rememberUrl('http://old.invalid/'),
        st.clearHistory(),
        st.rememberUrl('http://last.invalid/'),
      ]);
      expect(st.history, ['http://last.invalid/']);
      expect(jsonDecode(await file.readAsString()), st.history);
    },
  );

  test(
    'log truncates on enqueue and never retains the original payload',
    () async {
      final st = await _state();
      final bytes = Uint8List(2 * 1024 * 1024)
        ..fillRange(0, 2 * 1024 * 1024, 7);
      final event = Ev(1, 'rx', 'payload', bytes);
      st.sinkFor(LogSrc.single)(event);
      bytes.fillRange(0, bytes.length, 9);
      await _until(() => st.logs.isNotEmpty);
      final log = st.logs.single;
      expect(log.payload, hasLength(payloadKeepDefault));
      expect(log.payload!.every((b) => b == 7), isTrue);
      expect(log.e.data, isNull);
      expect(log.fullLen, bytes.length);
      expect(log.e.t, event.t);
      expect(st.logsFor(LogSrc.single).single, same(log));
    },
  );

  test(
    'manual certificate validation inherits, overrides, resets and persists',
    () async {
      final st = await _state();
      st.settings.verifyCerts = true;
      expect(st.stepVerify, isTrue);
      expect(st.step.verify, isNull);
      st.step.verify = false;
      expect(st.stepVerify, isFalse);
      st.savePrefs();
      final restored = AppState(settingsDir: st.settings.saveDir);
      addTearDown(() async {
        restored.dispose();
        await restored.flushHistory();
      });
      await restored.loadPrefs();
      expect(restored.stepVerify, isFalse);
      restored.step.verify = null;
      expect(restored.stepVerify, isTrue);
      restored.applyPrefs({
        'version': 1,
        'settings': {'verifyCerts': true},
        'step': {'verify': false},
      });
      expect(restored.step.verify, isNull);
      expect(restored.stepVerify, isTrue);
    },
  );
}
