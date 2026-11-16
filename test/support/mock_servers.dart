// Local mock servers used by tests (HTTP endpoints, SOCKS5 and HTTP CONNECT proxies).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class MockServers {
  late ServerSocket http, socks, connect;
  final big = Uint8List.fromList(
    List.generate(4 * 1024 * 1024, (i) => (i * 2654435761) >> 7 & 0xff),
  );
  final List<String> proxySeen = [];

  int get httpPort => http.port;
  int get socksPort => socks.port;
  int get connectPort => connect.port;

  Future<void> start() async {
    http = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    socks = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    connect = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    http.listen(_http);
    socks.listen((c) => _tunnel(c, _socksParse, true));
    connect.listen((c) => _tunnel(c, _connectParse, false));
  }

  Future<void> stop() async {
    await http.close();
    await socks.close();
    await connect.close();
  }

  void _http(Socket c) {
    final buf = <int>[];
    var busy = Future.value();
    c.listen(
      (d) {
        buf.addAll(d);
        busy = busy.then((_) => _serve(c, buf));
      },
      onDone: () => busy.then((_) => c.close()).catchError((_) => c),
      onError: (_) {},
      cancelOnError: true,
    );
  }

  Future<void> _serve(Socket c, List<int> buf) async {
    while (true) {
      final s = latin1.decode(buf);
      final i = s.indexOf('\r\n\r\n');
      if (i < 0) return;
      final req = s.substring(0, i);
      // Consume a request body when Content-Length says there is one, so keep-alive framing stays correct.
      final m = RegExp(
        r'^content-length:\s*(\d+)',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(req);
      final clen = m == null ? 0 : int.parse(m.group(1)!);
      if (buf.length < i + 4 + clen) return;
      final body = latin1.decode(buf.sublist(i + 4, i + 4 + clen));
      buf.removeRange(0, i + 4 + clen);
      final path = req.split(' ')[1];
      try {
        switch (path) {
          case '/big':
            c.add(
              latin1.encode(
                'HTTP/1.1 200 OK\r\nContent-Length: ${big.length}\r\n\r\n',
              ),
            );
            for (var o = 0; o < big.length; o += 512 * 1024) {
              c.add(big.sublist(o, min(o + 512 * 1024, big.length)));
              await c.flush();
              await Future.delayed(const Duration(milliseconds: 250));
            }
          case '/chunked':
            c.add(
              latin1.encode(
                'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nhello \r\n5\r\nworld\r\n0\r\n\r\n',
              ),
            );
          case '/cut':
            c.add(
              latin1.encode(
                'HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n${'x' * 100}',
              ),
            );
            await c.flush();
            c.destroy();
            return;
          case '/stall':
            c.add(
              latin1.encode('HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nab'),
            );
          case '/ka2s': // answers, then closes the idle keep-alive connection after 2s (like nginx keepalive_timeout)
            c.add(
              latin1.encode(
                'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok',
              ),
            );
            await c.flush();
            Future.delayed(
              const Duration(seconds: 2),
              () => c.close().catchError((_) => c),
            );
          case '/echo':
            final full = '$req\r\n\r\n$body';
            c.add(
              latin1.encode(
                'HTTP/1.1 200 OK\r\nContent-Length: ${full.length}\r\n\r\n$full',
              ),
            );
          default:
            c.add(
              latin1.encode(
                'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n',
              ),
            );
        }
      } catch (_) {
        return;
      }
    }
  }

  /// Returns (reply, host, port, consumed) once the request is complete, else null.
  (List<int>, String, int, int)? _socksParse(List<int> b, int stage) {
    if (stage == 0) {
      return b.length >= 2 && b.length >= 2 + b[1]
          ? ([5, 0], '', 0, 2 + b[1])
          : null;
    }
    if (b.length < 5) return null;
    if (b[3] == 3) {
      final l = b[4];
      if (b.length < 7 + l) return null;
      return (
        [5, 0, 0, 1, 0, 0, 0, 0, 0, 0],
        latin1.decode(b.sublist(5, 5 + l)),
        (b[5 + l] << 8) | b[6 + l],
        7 + l,
      );
    }
    if (b.length < 10) return null;
    return (
      [5, 0, 0, 1, 0, 0, 0, 0, 0, 0],
      b.sublist(4, 8).join('.'),
      (b[8] << 8) | b[9],
      10,
    );
  }

  (List<int>, String, int, int)? _connectParse(List<int> b, int stage) {
    final s = latin1.decode(b);
    final i = s.indexOf('\r\n\r\n');
    if (i < 0) return null;
    final t = s.split(' ')[1];
    final k = t.lastIndexOf(':');
    return (
      latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'),
      t.substring(0, k),
      int.parse(t.substring(k + 1)),
      i + 4,
    );
  }

  void _tunnel(
    Socket c,
    (List<int>, String, int, int)? Function(List<int>, int) parse,
    bool isSocks,
  ) {
    final buf = <int>[];
    var stage = 0;
    Socket? up;
    var connecting = false;
    c.listen(
      (d) async {
        if (up != null) {
          up!.add(d);
          return;
        }
        buf.addAll(d);
        if (connecting) return;
        while (true) {
          final r = parse(buf, stage);
          if (r == null) return;
          buf.removeRange(0, r.$4);
          if (isSocks && stage == 0) {
            c.add(r.$1);
            stage = 1;
            continue;
          }
          connecting = true;
          proxySeen.add('${isSocks ? 'socks5' : 'http'} ${r.$2}:${r.$3}');
          try {
            final u = await Socket.connect(r.$2, r.$3);
            c.add(r.$1);
            if (buf.isNotEmpty) u.add(buf);
            up = u;
            u.listen(
              c.add,
              onDone: () => c.close().catchError((_) => c),
              onError: (_) => c.destroy(),
              cancelOnError: true,
            );
          } catch (_) {
            c.add(
              isSocks
                  ? [5, 5, 0, 1, 0, 0, 0, 0, 0, 0]
                  : latin1.encode('HTTP/1.1 502 Bad Gateway\r\n\r\n'),
            );
            c.destroy();
          }
          return;
        }
      },
      onDone: () => up?.close().catchError((_) => up!),
      onError: (_) => up?.destroy(),
      cancelOnError: true,
    );
  }
}
