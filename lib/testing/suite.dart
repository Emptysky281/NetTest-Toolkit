// Feature checks shared by host tests (test/core_test.dart) and on-device tests (integration_test/).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/http.dart';
import '../core/platform.dart';
import '../core/proxy.dart';
import '../core/runner.dart';
import '../core/session.dart';
import '../core/tls_view.dart';
import '../core/util.dart';
import 'mock_servers.dart';

const real = 'http://64.83.22.144:1919/data/';

class SimpleError {
  /// Pull the most meaningful reason out of a (multi-line) error log.
  static String extract(String s) {
    const keys = [
      'CERTIFICATE_VERIFY_FAILED',
      'Hostname mismatch',
      'certificate has expired',
      'self signed certificate',
      'SocketException',
      'TimeoutException',
      'HandshakeException',
    ];
    for (final k in keys) {
      final i = s.indexOf(k);
      if (i >= 0) {
        final tail = s.substring(i).split('\n').first.trim();
        return tail.length > 140 ? tail.substring(0, 140) : tail;
      }
    }
    return s.split('\n').last;
  }
}

class Check {
  Check(this.name, this.ok, this.info);
  final String name;
  final bool ok;
  final String info;
}

class Suite {
  Suite(this.saveDir, {this.manualTls = false});
  final String saveDir;
  final bool manualTls;
  final results = <Check>[];
  final mock = MockServers();
  String get local => 'http://127.0.0.1:${mock.httpPort}';

  void check(String name, bool ok, [String info = '']) {
    results.add(Check(name, ok, info));
    // ignore: avoid_print
    print(
      '[${ok ? 'PASS' : 'FAIL'}] $name${info.isNotEmpty ? '  ($info)' : ''}',
    );
  }

  Future<(MultiRunner, List<Ev>)> run(
    String url, {
    ProxyConfig? proxy,
    int count = 1,
    int conc = 1,
    int requests = 1,
    bool keepAlive = true,
    double timeout = 8,
    bool split = false,
    String headers = '',
    String? payload,
  }) async {
    final ev = <Ev>[];
    final r = MultiRunner(
      HttpJob(
        url,
        requestsPerConn: requests,
        keepAlive: keepAlive,
        timeout: timeout,
        splitSend: split,
        splitDelay: split ? 0.1 : 0,
        headers: headers,
        body: payload == null ? null : unescape(payload),
      ),
      proxy ?? ProxyConfig(),
      ev.add,
      count: count,
      concurrency: conc,
      verbose: true,
      bindRange: (42000, 42999),
      saveDir: saveDir,
    );
    r.start();
    await r.done;
    return (r, ev);
  }

  String msgs(List<Ev> ev) => ev.map((e) => e.msg).join('\n');
  String read(String name) =>
      File('$saveDir${Platform.pathSeparator}$name').readAsStringSync();
  bool exists(String name) =>
      File('$saveDir${Platform.pathSeparator}$name').existsSync();

  Future<void> all() async {
    Directory(saveDir).createSync(recursive: true);
    await mock.start();
    for (final t in <(String, Future<void> Function())>[
      ('units', units),
      ('real_single', realSingle),
      ('real_multi', realMulti),
      ('split', splitSend),
      ('payload', payloadSend),
      ('per_conn_url', perConnUrl),
      ('no_tls', noTlsTest),
      ('step_tcp', stepTcp),
      ('tls_auto', tlsAuto),
      if (manualTls) ('tls_manual', tlsManual),
      ('proxy', proxyTests),
      ('download', download),
      ('ports', portsTest),
      ('certs', certTests),
      ('live', liveStatus),
      ('waitForever', waitForever),
    ]) {
      // ignore: avoid_print
      print('--- ${t.$1}');
      try {
        // certs makes 10+ TLS connections to badssl.com, which is sometimes slow; give it more time
        await t.$2().timeout(Duration(seconds: t.$1 == 'certs' ? 240 : 90));
      } catch (e, st) {
        check('${t.$1} 异常', false, '$e\n$st');
      }
    }
    await mock.stop();
  }

  Future<void> units() async {
    check(
      'unescape 转义',
      listEq(unescape(r'a\r\n\x41\t中'), [97, 13, 10, 65, 9, 0xE4, 0xB8, 0xAD]),
    );
    final p = HttpResponseParser()..expectNoBody.add(false);
    final got = <int>[];
    p.onBody = (r, d) => got.addAll(d);
    final data = 'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;x=1\r\nde\r\n0\r\nT: 1\r\n\r\n'
        .codeUnits;
    final fin = <HttpResp>[];
    for (final b in data) {
      fin.addAll(p.feed([b]));
    }
    check(
      '解析器 100-continue + chunked + trailer(逐字节)',
      fin.length == 1 && String.fromCharCodes(got) == 'abcde',
    );
    final p2 = HttpResponseParser()..expectNoBody.addAll([true, false]);
    final f2 = p2.feed(
      'HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n'
          .codeUnits,
    );
    check(
      '解析器 HEAD/204 无正文',
      listEq(f2.map((r) => r.code).toList(), [200, 204]),
    );
    check(
      'TLS 记录识别非 TLS',
      TlsRecordView().feed('HTTP/1.1 400'.codeUnits).first.contains('非 TLS'),
    );
    check(
      'FakeIP 段识别',
      ipNote('198.18.0.5').contains('FakeIP') && ipNote('8.8.8.8').isEmpty,
    );
    check(
      '文件名同 curl -O',
      targetName('/a/b/2.txt?x=1') == '2.txt' &&
          targetName('/') == 'index.html' &&
          targetName('/1.txt', '_c1_r2') == '1_c1_r2.txt',
    );
    check(
      '百分位',
      percentile([1, 2, 3, 4], 50) == 2.5 && percentile([5], 95) == 5,
    );
    check(
      '二进制检测',
      isBinary(List.generate(256, (i) => i)) &&
          !isBinary('HTTP/1.1 200 OK\r\n'.codeUnits),
    );
    check('文本视图去掉 \\r', !textView('a\r\nb\r'.codeUnits).contains('\r'));
  }

  Future<void> realSingle() async {
    var (r, ev) = await run('${real}1.txt', requests: 3);
    final s = r.sessions.first;
    check(
      '真实服务器 单连接 keep-alive 3 次请求',
      listEq(s.parser.done.map((x) => x.code).toList(), [200, 200, 200]),
      msgs(ev).split('\n').where((l) => l.contains('失败')).join(),
    );
    check(
      '真实服务器 下载 1.txt 内容正确',
      exists('1_c${s.cid}_r1.txt') && read('1_c${s.cid}_r1.txt') == '1',
    );
    check('记录 DNS/TCP/TTFB', ['dns', 'tcp', 'ttfb'].every(s.stats.containsKey));
    check('绑定端口段 42000-42999', ev.any((e) => e.msg.contains('本地端口 42')));
    (r, ev) = await run('${real}2.txt', keepAlive: false);
    check('Connection: close 后对端关闭', msgs(ev).contains('收到 FIN'));
    check('单次请求按原名保存 2.txt', read('2.txt') == '2');
  }

  Future<void> realMulti() async {
    final (r, ev) = await run('${real}2.txt', count: 40, conc: 10, requests: 2);
    final ok = r.sessions.where((s) => s.ok == 2).length;
    check('真实服务器 40 连接 x2 请求 并发 10', ok == 40, '$ok/40');
    final sm = r.summary!;
    final tcp = sm['tcp'] as Map<String, double>;
    check(
      '汇总统计 p50/p95',
      sm['fullOk'] == 40 && tcp['p95']! >= tcp['p50']!,
      sm['short'] as String,
    );
    // 并发上限 bounds in-flight work (connect + requests); idle kept-alive connections don't count.
    final spans = [
      for (final s in r.sessions)
        (
          s.t0,
          s.tRequestsDone > 0
              ? s.tRequestsDone
              : s.t0 + (s.stats['duration'] ?? 0),
        ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    var peak = 0;
    for (final (a, _) in spans) {
      final c = spans.where((x) => x.$1 <= a && a < x.$2).length;
      if (c > peak) peak = c;
    }
    check('并发上限生效', peak <= 10, '峰值 $peak');
  }

  Future<void> splitSend() async {
    var (r, ev) = await run('$local/echo', split: true);
    final tx = ev.where((e) => e.kind == 'tx').map((e) => e.msg).toList();
    check(
      '请求分段发送(请求行/头/空行)',
      tx.length == 3 && tx[0].contains('请求行') && tx[2].contains('空行'),
      tx.join(' | '),
    );
    (r, ev) = await run(
      '$local/echo',
      headers: 'User-Agent: curl/8.0\nX-Test: 1',
    );
    final body = read('echo');
    check(
      '附加请求头覆盖 UA',
      body.contains('User-Agent: curl/8.0') &&
          body.contains('X-Test: 1') &&
          !body.contains('NetTestClient'),
    );
  }

  /// [timeout] = reply wait; remote test hosts (badssl.com) sometimes take several seconds per handshake flight.
  TcpSession _sess(String host, int port, List<Ev> ev, {double timeout = 8}) =>
      TcpSession(host, port, ProxyConfig(), ev.add, timeout: timeout);

  /// Custom payload on single and multi connection runs: the body and its Content-Length must
  /// reach the server, and multi must send the same bytes on every connection.
  Future<void> payloadSend() async {
    const p = r'k1=v1&k2=中\r\nX-Tail: 1';
    await run('$local/echo', payload: p);
    var body = read('echo');
    check(
      '单连接 自定义载荷作为正文发送',
      body.contains('\r\n\r\nk1=v1&k2=中\r\nX-Tail: 1'),
      body
          .replaceAll('\r', '\\r')
          .replaceAll('\n', '\\n')
          .split('\r\n\r\n')
          .last,
    );
    check(
      '单连接 自动 Content-Length',
      body.toLowerCase().contains('content-length: ${unescape(p).length}'),
    );

    final (r, _) = await run(
      '$local/echo',
      count: 4,
      conc: 2,
      requests: 2,
      keepAlive: false,
      payload: 'multi-body',
    );
    final echoes = Directory(saveDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('echo_c'))
        .map((f) => f.readAsStringSync())
        .toList();
    check(
      '多连接 载荷同样发送',
      r.sessions.every((s) => s.ok == 2) &&
          echoes.length == 8 &&
          echoes.every((b) => b.contains('\r\n\r\nmulti-body')),
      '${echoes.length} 个响应体',
    );
    check(
      '多连接 自动 Content-Length 10',
      echoes.isNotEmpty &&
          echoes.every((b) => b.toLowerCase().contains('content-length: 10')),
    );
    // no payload configured -> byte-identical request as before (no stray Content-Length)
    await run('$local/echo');
    check(
      '空载荷不发送 Content-Length',
      !read('echo').toLowerCase().contains('content-length'),
    );
  }

  /// Multi mode with a URL per connection: each connection requests its own URL, a blank entry
  /// falls back to the job URL, and every table row reports the URL it used.
  Future<void> perConnUrl() async {
    final ev = <Ev>[];
    final r = MultiRunner(
      HttpJob('$local/echo', keepAlive: false),
      ProxyConfig(),
      ev.add,
      count: 4,
      concurrency: 2,
      verbose: true,
      saveDir: saveDir,
      urls: ['$local/chunked', '', '$local/ka2s', '$local/chunked?x=1'],
    );
    r.start();
    await r.done;
    final want = [
      '$local/chunked',
      '$local/echo',
      '$local/ka2s',
      '$local/chunked?x=1',
    ];
    final rows = <int, RowData>{
      for (final e in ev.where((e) => e.kind == 'row'))
        (e.data as RowData).idx: e.data as RowData,
    };
    final got = [for (var i = 1; i <= 4; i++) rows[i]?.url];
    check(
      '每条连接 URL: 行显示各自的 URL（空 = 目标 URL）',
      got.join('\n') == want.join('\n'),
      got.join(' | '),
    );
    final paths = [
      for (final s in r.sessions..sort((a, b) => a.rowIdx.compareTo(b.rowIdx)))
        s.parser.done.map((x) => x.path).join(),
    ];
    check(
      '每条连接 URL: 实际请求各自的路径',
      paths.join(' ') == '/chunked /echo /ka2s /chunked?x=1',
      paths.join(' | '),
    );
    check(
      '每条连接 URL: 全部成功',
      r.sessions.every((s) => s.ok == 1) && r.summary!['fullOk'] == 4,
      r.summary!['short'] as String,
    );
    final single = MultiRunner(
      HttpJob('$local/echo'),
      ProxyConfig(),
      (_) {},
      count: 2,
    );
    check(
      '未设置每条 URL 时都用目标 URL',
      single.urlFor(1) == '$local/echo' && single.urlFor(2) == '$local/echo',
    );
  }

  /// https:// URL pointed at the plain-text mock: normally TLS fails; with noTls the request goes out
  /// in plain text right after the TCP handshake, with Host and port unchanged.
  Future<void> noTlsTest() async {
    final url = 'https://127.0.0.1:${mock.httpPort}/echo';
    Future<(MultiRunner, List<Ev>)> go(bool noTls) async {
      final ev = <Ev>[];
      final r = MultiRunner(
        HttpJob(url, keepAlive: false, timeout: 3, connectTimeout: 3),
        ProxyConfig(),
        ev.add,
        count: 2,
        concurrency: 2,
        verbose: true,
        saveDir: saveDir,
        noTls: noTls,
      );
      r.start();
      await r.done;
      return (r, ev);
    }

    var (r, ev) = await go(true);
    final echoes = Directory(saveDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('echo_c'))
        .map((f) => f.readAsStringSync())
        .toList();
    check(
      '不做 TLS: https 连接 TCP 握手后直接发明文请求',
      r.sessions.length == 2 && r.sessions.every((s) => s.ok == 1),
      r.summary!['short'] as String,
    );
    check(
      '不做 TLS: Host 头与端口不变',
      echoes.any((b) => b.contains('Host: 127.0.0.1:${mock.httpPort}')),
    );
    check('不做 TLS: 日志说明未做 TLS', ev.any((e) => e.msg.contains('不做 TLS')));
    (r, ev) = await go(false);
    check(
      '对照: 不勾选时照常做 TLS（明文服务器上失败）',
      r.sessions.every((s) => s.ok == 0),
      r.summary!['short'] as String,
    );
  }

  Future<void> stepTcp() async {
    final ev = <Ev>[];
    var s = _sess('127.0.0.1', mock.httpPort, ev)..setSave(saveDir);
    await s.connect();
    final parts = buildHttpRequest(
      'GET',
      '127.0.0.1',
      mock.httpPort,
      '/chunked',
    );
    s.expectResponse('GET', '/chunked');
    for (final p in parts.take(3)) {
      await s.send(p);
      await Future.delayed(const Duration(milliseconds: 150));
    }
    var ok = await s.waitResponses(1, 3);
    check('分阶段: 请求行/头/空行手动发送', ok && read('chunked') == 'hello world');
    s.expectResponse('GET', '/echo');
    await s.sendChunked(
      Uint8List.fromList([
        for (final p in buildHttpRequest(
          'GET',
          '127.0.0.1',
          mock.httpPort,
          '/echo',
        ))
          ...p,
      ]),
      7,
      0.02,
    );
    ok = await s.waitResponses(2, 3);
    check(
      '分阶段: 按 7 字节分片发送',
      ok && ev.where((e) => e.msg.contains('分片[')).length > 10,
    );
    s.shutdownWrite();
    await Future.delayed(const Duration(milliseconds: 500));
    check('半关闭后对端关闭', s.state == 'closed', s.state);
    ev.clear();
    s = _sess('127.0.0.1', mock.httpPort, ev);
    await s.connect();
    s.reset();
    check(
      'RST 关闭',
      msgs(ev).contains('RST') && !msgs(ev).contains('失败'),
      msgs(ev).split('\n').last,
    );
  }

  Future<void> tlsAuto() async {
    final (r, ev) = await run('https://example.com/');
    final s = r.sessions.first;
    check(
      'HTTPS 自动模式',
      s.parser.done.isNotEmpty &&
          s.parser.done.first.code == 200 &&
          read('index.html').contains('Example Domain'),
      msgs(ev)
          .split('\n')
          .where((l) => l.contains('TLS') || l.contains('失败'))
          .join(' | '),
    );
  }

  Future<void> tlsManual() async {
    final ev = <Ev>[];
    var s = _sess('example.com', 443, ev)..setSave(saveDir);
    await s.connect();
    await s.tlsBegin('example.com', verify: true, alpn: 'http/1.1');
    await s.tlsSendNext(chunk: 50, delay: 0.01);
    await Future.delayed(const Duration(milliseconds: 1500));
    check(
      'TLS: ClientHello 分片发送且带 SNI',
      msgs(ev).contains('ClientHello SNI=example.com') &&
          msgs(ev).contains('ClientHello 分片['),
    );
    check(
      'TLS: 发 ClientHello 后停住，未自动完成',
      !s.tlsDone && msgs(ev).contains('ServerHello'),
    );
    for (var i = 0; i < 3 && !s.tlsDone; i++) {
      await s.tlsSendNext();
      await Future.delayed(const Duration(seconds: 1));
    }
    check(
      'TLS: 手动继续握手完成',
      s.tlsDone,
      ev
          .where((e) => e.msg.contains('握手完成') || e.kind == 'err')
          .map((e) => e.msg)
          .join(' | '),
    );
    s.expectResponse('GET', '/');
    await s.send(
      Uint8List.fromList([
        for (final p in buildHttpRequest(
          'GET',
          'example.com',
          443,
          '/',
          scheme: 'https',
        ))
          ...p,
      ]),
    );
    final ok = await s.waitResponses(1, 8);
    check(
      'TLS: 加密请求并保存解密正文',
      ok && read('index.html').contains('Example Domain'),
    );
    s.close();
    ev.clear();
    s = _sess('64.83.22.144', 1919, ev);
    await s.connect();
    await s.tlsBegin('64.83.22.144');
    await s.tlsSendNext();
    // remote server: wait for its plain-text reply instead of a fixed 1 s (it is sometimes slower)
    for (var i = 0; i < 30 && !msgs(ev).contains('不是 TLS'); i++) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    check('TLS: 识别非 TLS 端口', msgs(ev).contains('不是 TLS'));
  }

  Future<void> proxyTests() async {
    mock.proxySeen.clear();
    var (r, ev) = await run(
      '${real}1.txt',
      proxy: ProxyConfig(mode: 'socks5', port: mock.socksPort),
    );
    check(
      'SOCKS5 代理',
      r.sessions.first.ok == 1 &&
          mock.proxySeen.lastOrNull?.startsWith('socks5') == true,
      msgs(ev).split('\n').where((l) => l.contains('失败')).join(),
    );
    (r, ev) = await run(
      '${real}1.txt',
      proxy: ProxyConfig(mode: 'http', port: mock.connectPort),
    );
    check(
      'HTTP CONNECT 代理',
      r.sessions.first.ok == 1 && mock.proxySeen.last.startsWith('http'),
    );
    (r, ev) = await run(
      'https://example.com/',
      proxy: ProxyConfig(mode: 'socks5', port: mock.socksPort),
    );
    check(
      'SOCKS5 + HTTPS',
      r.sessions.first.parser.done.isNotEmpty &&
          mock.proxySeen.last.contains('example.com'),
      msgs(ev)
          .split('\n')
          .where((l) => l.contains('失败') || l.contains('错误'))
          .join(),
    );
    (r, ev) = await run(
      '${real}1.txt',
      proxy: ProxyConfig(mode: 'socks5', port: 1),
    );
    check('代理不可达时报错', msgs(ev).contains('连接失败'));
    final sp = await ProxyConfig(mode: 'system').resolved();
    check(
      'system 模式(未设置时回落直连)',
      ['direct', 'http'].contains(sp.mode),
      sp.describe(),
    );
  }

  Future<void> download() async {
    final t = now();
    var (r, ev) = await run('$local/big', timeout: 1.0);
    final el = now() - t;
    final f = File('$saveDir${Platform.pathSeparator}big');
    check(
      '4MB 限速下载 >空闲超时 仍完成且内容一致',
      f.existsSync() && listEq(f.readAsBytesSync(), mock.big) && el > 1.5,
      '${el.toStringAsFixed(1)}s',
    );
    check('下载进度与速度', msgs(ev).contains('下载中') && msgs(ev).contains('%'));
    check('大文件 RX 日志限流', ev.where((e) => e.kind == 'rx').length <= rxLogQuota);
    (r, ev) = await run('$local/cut');
    check(
      '中途断开存为 .incomplete',
      exists('cut.incomplete') && msgs(ev).contains('不完整'),
    );
    (r, ev) = await run('$local/stall', timeout: 1.5);
    check('回包超时', msgs(ev).contains('回包超时'));
    await Future.delayed(const Duration(milliseconds: 300));
    check(
      '下载目录无残留 .part',
      Directory(saveDir).listSync().every((e) => !e.path.endsWith('.part')),
      Directory(saveDir)
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .where((n) => n.endsWith('.part'))
          .join(','),
    );
  }

  /// Certificate handling: by default untrusted certs are accepted (and logged);
  /// 强制校验证书=on must reject bad chains, hostname mismatches and expired certs.
  Future<void> certTests() async {
    Future<(MultiRunner, String)> fetch(
      String url, {
      bool verify = false,
      double timeout = 12,
    }) async {
      MultiRunner? run;
      var m = '';
      // badssl hosts occasionally time out; retry once so a network blip is not a test failure.
      for (var attempt = 0; attempt < 5; attempt++) {
        final ev = <Ev>[];
        run = MultiRunner(
          HttpJob(url, timeout: timeout, verifyCerts: verify),
          ProxyConfig(),
          ev.add,
          count: 1,
          concurrency: 1,
          verbose: true,
          bindRange: (42000, 42999),
          saveDir: saveDir,
        );
        run.start();
        await run.done;
        m = msgs(ev);
        final s = run.sessions.isEmpty ? null : run.sessions.first;
        // retry only network problems (timeouts / unreachable); a certificate rejection is the result we want
        final err = s?.error ?? '';
        final networkIssue =
            s == null ||
            !s.stats.containsKey('tcp') ||
            err.contains('超时') ||
            err.contains('Timeout') ||
            err.contains('SocketException') ||
            err.contains('Connection terminated');
        if (!networkIssue) break;
        await Future.delayed(Duration(milliseconds: 800 * (attempt + 1)));
      }
      return (run!, m);
    }

    // default (no verification): every badssl host must connect
    for (final h in [
      'self-signed',
      'expired',
      'wrong.host',
      'untrusted-root',
    ]) {
      final (r, m) = await fetch('https://$h.badssl.com/');
      final ok = r.sessions.first.parser.done.isNotEmpty;
      check(
        '默认不校验: $h 可连接',
        r.sessions.first.stats.containsKey('tcp') && !m.contains('连接失败'),
        m.split('\n').where((l) => l.contains('失败')).join(' | '),
      );
      check(
        '默认不校验: $h 记录证书信息',
        m.contains('已接受不被信任的证书') || m.contains('subject='),
        m
            .split('\n')
            .where((l) => l.contains('证书') || l.contains('subject='))
            .join(' | '),
      );
      if (!ok) {
        check(
          '默认不校验: $h 无 HTTP 响应时已完成 TLS',
          r.sessions.first.stats.containsKey('tls') && !m.contains('连接失败'),
          '无完整 HTTP 响应，必须实际完成 TLS 握手，不能无条件通过',
        );
      }
    }

    // 强制校验证书 = on
    final cases = {
      'self-signed': 'CERTIFICATE_VERIFY_FAILED',
      'expired': 'CERTIFICATE_VERIFY_FAILED',
      'wrong.host': 'CERTIFICATE_VERIFY_FAILED',
      'untrusted-root': 'CERTIFICATE_VERIFY_FAILED',
    };
    for (final e in cases.entries) {
      final (r, m) = await fetch('https://${e.key}.badssl.com/', verify: true);
      final reason = SimpleError.extract(m);
      check(
        '强制校验: ${e.key} 被拒',
        m.contains('连接失败') && reason.contains(e.value),
        reason,
      );
    }
    // Use a host that serves a complete chain: example.com omits its intermediate, and
    // BoringSSL (unlike Windows schannel) does not fetch it via AIA.
    final (_, good) = await fetch('https://www.baidu.com/', verify: true);
    check('强制校验: 正常证书仍可连', !good.contains('连接失败'), good.split('\n').last);

    if (!manualTls) return;
    // manual TLS inherits the same default (accept) and can still be forced to verify per run
    final ev = <Ev>[];
    var s = _sess('self-signed.badssl.com', 443, ev, timeout: 20)
      ..setSave(saveDir);
    var ok = await s.connect();
    for (var a = 0; a < 2 && !ok; a++) {
      await Future.delayed(const Duration(milliseconds: 500));
      final retry = _sess('self-signed.badssl.com', 443, ev, timeout: 20)
        ..setSave(saveDir);
      ok = await retry.connect();
      if (ok) s = retry;
    }
    if (!ok) {
      check('手动 TLS 默认: 自签名可通过', false, '连接失败(重试后仍不可达)，跳过');
      return;
    }
    // badssl.com occasionally drops the connection right after the ClientHello; reconnect and retry
    // (a real verification failure is not retried: it fails the same way every time)
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        s.close();
        await Future.delayed(const Duration(milliseconds: 800));
        s = _sess('self-signed.badssl.com', 443, ev, timeout: 20)
          ..setSave(saveDir);
        if (!await s.connect()) continue;
      }
      await s.tlsBegin(
        'self-signed.badssl.com',
      ); // no explicit verify -> settings default (accept)
      // normally 3 rounds; allow more for a slow remote reply, stop as soon as it finishes or fails
      for (var i = 0; i < 10 && !s.tlsDone && !s.tlsFailed; i++) {
        await s.tlsSendNext();
        await Future.delayed(const Duration(milliseconds: 900));
      }
      if (s.tlsDone || !(s.lastTlsError ?? '').contains('连接已关闭')) break;
    }
    check('手动 TLS 默认: 自签名可通过', s.tlsDone, s.lastTlsError ?? '');
    if (s.tlsDone) {
      s.expectResponse('GET', '/');
      await s.send(
        Uint8List.fromList([
          for (final p in buildHttpRequest(
            'GET',
            'self-signed.badssl.com',
            443,
            '/',
            scheme: 'https',
          ))
            ...p,
        ]),
      );
      check(
        '手动 TLS 默认: 能拿到响应',
        await s.waitResponses(1, 8) && s.parser.done.first.code == 200,
      );
    }
    s.close();

    final ev2 = <Ev>[];
    s = _sess('self-signed.badssl.com', 443, ev2, timeout: 20);
    var connected = await s.connect();
    for (var a = 0; a < 2 && !connected; a++) {
      await Future.delayed(const Duration(milliseconds: 500));
      final retry = _sess('self-signed.badssl.com', 443, ev2, timeout: 20);
      connected = await retry.connect();
      if (connected) s = retry;
    }
    if (!connected) {
      check('手动 TLS 强制校验: 自签名被拒并回证书告警', false, '连接失败(重试后仍不可达)，跳过');
      return;
    }
    await s.tlsBegin(
      'self-signed.badssl.com',
      verify: true,
    ); // force verification
    for (var i = 0; i < 6 && !s.tlsDone && !s.tlsFailed; i++) {
      await s.tlsSendNext();
      await Future.delayed(const Duration(milliseconds: 900));
    }
    final cerr = s.lastTlsError ?? '';
    // fatal certificate alert back to the server: Android's SSLEngine sends 46 certificate_unknown,
    // OpenSSL (Windows) sends 48 unknown_ca for a self-signed chain; both are correct
    final alerted = ev2.any(
      (e) =>
          e.msg.contains('Alert') &&
          (e.msg.contains('desc=46') || e.msg.contains('desc=48')),
    );
    check(
      '手动 TLS 强制校验: 自签名被拒并回证书告警',
      !s.tlsDone &&
          (cerr.contains('CertPathValidatorException') ||
              cerr.contains('CERTIFICATE_VERIFY_FAILED')) &&
          alerted,
      '$cerr alerted=$alerted',
    );
    s.close();
  }

  /// Live connection status must come from the receive path only (no probing packets),
  /// and keep-alive + 保持 must leave the connection visibly open.
  Future<void> liveStatus() async {
    final ev = <Ev>[];
    final r = MultiRunner(
      HttpJob('${real}1.txt', keepAlive: true, hold: 4, timeout: 8),
      ProxyConfig(),
      ev.add,
      count: 2,
      concurrency: 2,
      verbose: true,
      bindRange: (42000, 42999),
      saveDir: saveDir,
    );
    r.start();
    // wait for both connections to finish their requests and enter the hold window
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 6000) {
      await Future.delayed(const Duration(milliseconds: 100));
      // holding is true during the post-request keep-alive window (s.ok is only set afterwards)
      if (r.sessions.length == 2 && r.sessions.every((s) => s.holding)) break;
    }
    check(
      '保持中: 连接保持打开',
      r.sessions.length == 2 &&
          r.sessions.every((s) => s.state == 'established'),
      '${r.sessions.map((s) => s.state).join(',')} holding=${r.sessions.map((s) => s.holding).join(',')}',
    );
    final before = r.sessions.fold<int>(0, (a, s) => a + s.txBytes + s.rxBytes);
    final live = r.sessions.map((s) => s.passive()).toList();
    check(
      '保持中: 被动状态为 opens',
      live.every((l) => l.open) && live.first.idle >= 0,
      live
          .map(
            (l) =>
                '${l.state} up=${l.up.toStringAsFixed(1)} idle=${l.idle.toStringAsFixed(1)}',
          )
          .join(' | '),
    );
    // row events during the hold must carry live uptime/idle
    await Future.delayed(const Duration(milliseconds: 1200));
    final rows = ev
        .where((e) => e.kind == 'row')
        .map((e) => e.data as RowData)
        .where((r) => r.status == '保持中')
        .toList();
    if (r.sessions.any((s) => s.state != 'established')) {
      check(
        '保持中: 表格实时刷新持续/空闲',
        rows.isNotEmpty,
        'rows=${rows.length} (连接已提前结束)',
      );
    }
    check(
      '保持中: 表格实时刷新持续/空闲',
      rows.length >= 2 && rows.last.uptime > 0,
      rows.isEmpty
          ? 'no rows'
          : 'rows=${rows.length} uptime=${rows.last.uptime.toStringAsFixed(1)} idle=${rows.last.idle.toStringAsFixed(1)}',
    );
    final after = r.sessions.fold<int>(0, (a, s) => a + s.txBytes + s.rxBytes);
    check('保持中: 未主动发包探测', after == before, 'before=$before after=$after');
    await r.done;

    // keep-alive + 保持=0 + more connections than the concurrency limit: every connection must
    // get its request done (idle kept-alive ones don't block the slots), then stay open until 停止.
    final ev2 = <Ev>[];
    final r2 = MultiRunner(
      HttpJob('$local/echo', keepAlive: true, hold: 0, timeout: 5),
      ProxyConfig(),
      ev2.add,
      count: 6,
      concurrency: 2,
      verbose: false,
      bindRange: (42000, 42999),
      saveDir: saveDir,
    );
    r2.start();
    final sw2 = Stopwatch()..start();
    while (sw2.elapsedMilliseconds < 8000 &&
        !(r2.sessions.length == 6 && r2.sessions.every((s) => s.ok == 1))) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    check(
      'keep-alive 保持=0 且连接数>并发: 全部请求完成不死锁',
      r2.sessions.length == 6 && r2.sessions.every((s) => s.ok == 1),
      'n=${r2.sessions.length} ok=${r2.sessions.map((s) => s.ok).join(',')}',
    );
    await Future.delayed(const Duration(milliseconds: 800));
    check(
      'keep-alive 保持=0: 请求完成后连接仍保持打开',
      r2.running && r2.sessions.every((s) => s.state == 'established'),
      'running=${r2.running} ${r2.sessions.map((s) => s.state).join(',')}',
    );
    r2.cancel();
    var stopped = true;
    await r2.done.timeout(
      const Duration(seconds: 5),
      onTimeout: () => stopped = false,
    );
    check(
      'keep-alive 保持=0: 点停止后结束并关闭全部连接',
      stopped && r2.sessions.every((s) => s.state == 'closed'),
      'stopped=$stopped ${r2.sessions.map((s) => s.state).join(',')}',
    );

    // server closes the idle keep-alive connection: detected passively and shown as 对端断开
    final ev3 = <Ev>[];
    final r3 = MultiRunner(
      HttpJob('$local/ka2s', keepAlive: true, hold: 0, timeout: 5),
      ProxyConfig(),
      ev3.add,
      count: 2,
      concurrency: 2,
      verbose: false,
      bindRange: (42000, 42999),
      saveDir: saveDir,
    );
    r3.start();
    var ended = true;
    await r3.done.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        ended = false;
        r3.cancel();
      },
    );
    final rows3 = ev3
        .where((e) => e.kind == 'row')
        .map((e) => e.data as RowData)
        .toList();
    final last3 = {for (final r in rows3) r.idx: r};
    check(
      '对端关闭空闲连接: 被动检测并显示「对端断开」',
      ended && last3.values.every((r) => r.status == '对端断开'),
      'ended=$ended ${last3.values.map((r) => '${r.status} up=${r.uptime.toStringAsFixed(1)}').join(' | ')}',
    );
    check(
      '对端断开: 显示存活时长约 2s',
      last3.values.every((r) => r.uptime > 1.5 && r.uptime < 4),
      last3.values.map((r) => r.uptime.toStringAsFixed(2)).join(','),
    );
    // no response within the idle timeout: the connection is closed (FIN), not held open
    final ev4 = <Ev>[];
    final r4 = MultiRunner(
      HttpJob('$local/stall', keepAlive: true, hold: 0, timeout: 1.5),
      ProxyConfig(),
      ev4.add,
      count: 2,
      concurrency: 2,
      verbose: true,
      bindRange: (42000, 42999),
      saveDir: saveDir,
    );
    r4.start();
    var ended4 = true;
    await r4.done.timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        ended4 = false;
        r4.cancel();
      },
    );
    final m4 = msgs(ev4);
    check(
      '空闲超时: keep-alive 下也会关闭连接(不进入保持)',
      ended4 &&
          r4.sessions.every((s) => s.state == 'closed') &&
          '本地 close() (FIN)'.allMatches(m4).length == 2,
      'ended=$ended4 ${r4.sessions.map((s) => s.state).join(',')}',
    );
    check(
      '回包超时: 原因写入连接的错误列',
      r4.sessions.every((s) => (s.error ?? '').contains('回包超时')),
      r4.sessions.map((s) => s.error).join(' | '),
    );

    final txt3 = r3.summary!['text'] as String;
    check(
      '吞吐不计入 keep-alive 保持时间',
      txt3.contains('其余为 keep-alive 保持时间') && !txt3.contains('整体吞吐 0B/s'),
      txt3.split('\n').firstWhere((l) => l.contains('吞吐'), orElse: () => txt3),
    );
  }

  /// 回包超时=0: connection stays open waiting, no app-side timeout, nothing extra sent.
  /// 连接超时=0: the app does not give up on its own (the OS SYN retries decide).
  Future<void> waitForever() async {
    final ev = <Ev>[];
    final s = TcpSession(
      '127.0.0.1',
      mock.httpPort,
      ProxyConfig(),
      ev.add,
      timeout: 0,
      connectTimeout: 0,
    );
    await s.connect();
    s.expectResponse('GET', '/stall');
    await s.send(
      Uint8List.fromList([
        for (final p in buildHttpRequest(
          'GET',
          '127.0.0.1',
          mock.httpPort,
          '/stall',
        ))
          ...p,
      ]),
    );
    final tx0 = s.txBytes;
    var done = false;
    s.waitResponses(1, 0).then((_) => done = true);
    await Future.delayed(const Duration(seconds: 12));
    check(
      '回包超时=0: 12s 无回包仍保持连接等待',
      !done && s.state == 'established',
      'state=${s.state} done=$done',
    );
    check('回包超时=0: 等待期间不发任何包', s.txBytes == tx0, 'tx $tx0 -> ${s.txBytes}');
    check(
      '回包超时=0: 被动显示等待进度',
      msgs(ev).contains('等待回包中') && msgs(ev).contains('不限时'),
      ev.where((e) => e.msg.contains('等待回包')).map((e) => e.msg).join(' | '),
    );
    if (Platform.isAndroid || Platform.isLinux) {
      check(
        '回包超时=0: TCP_USER_TIMEOUT 设为不限',
        msgs(ev).contains('TCP_USER_TIMEOUT=不限'),
        ev
            .where((e) => e.msg.contains('TCP_USER_TIMEOUT'))
            .map((e) => e.msg)
            .join(),
      );
    }
    if (Platform.isWindows) {
      check(
        '回包超时=0: TCP_MAXRT 设为不限',
        msgs(ev).contains('TCP_MAXRT=不限'),
        ev.where((e) => e.msg.contains('TCP_MAXRT')).map((e) => e.msg).join(),
      );
    }
    s.close();

    // connect phase: unroutable address, app limit 0 -> still waiting after 10s (old default gave up at 8s)
    final ev2 = <Ev>[];
    final s2 = TcpSession(
      '10.255.255.1',
      80,
      ProxyConfig(),
      ev2.add,
      connectTimeout: 0,
    );
    var res = 'pending';
    s2.connect().then((ok) => res = ok ? 'ok' : 'failed: ${s2.error}');
    await Future.delayed(const Duration(seconds: 10));
    final stillWaiting = res == 'pending';
    check(
      '连接超时=0: 超过 8s 仍在等待 SYN-ACK（不由本程序放弃）',
      stillWaiting || res.contains('系统放弃'),
      res,
    );
    check(
      '连接超时=0: 被动显示 SYN 等待进度',
      msgs(ev2).contains('等待 SYN-ACK'),
      ev2.where((e) => e.msg.contains('SYN')).map((e) => e.msg).join(' | '),
    );
    s2.close();
    await Future.delayed(const Duration(milliseconds: 300));
    check(
      '连接超时=0: 点停止可取消等待中的连接',
      res != 'pending' || msgs(ev2).contains('已取消'),
      res,
    );
  }

  Future<void> portsTest() async {
    final hold = [
      for (final p in [43000, 43001])
        await ServerSocket.bind(InternetAddress.anyIPv4, p),
    ];
    ports.next = 43000;
    final ev = <Ev>[];
    final s = TcpSession(
      '127.0.0.1',
      mock.httpPort,
      ProxyConfig(),
      ev.add,
      bindRange: (43000, 43005),
    );
    final ok = await s.connect();
    check(
      '端口被占用时自动换端口',
      ok && s.sock!.port == 43002,
      '${s.sock?.port} ${s.error ?? ''}',
    );
    s.close();
    for (final h in hold) {
      await h.close();
    }
  }
}

bool listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<String> testSaveDir() async {
  if (Platform.isAndroid) return '${await Native.defaultSaveDir()}_test';
  return '${Directory.systemTemp.path}${Platform.pathSeparator}nettest_flutter_test';
}
