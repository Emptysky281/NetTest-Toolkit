// HTTP job on a session + multi-connection runner with bounded concurrency and summary stats.
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'http.dart';
import 'proxy.dart';
import 'session.dart';
import 'util.dart';

class HttpJob {
  HttpJob(
    this.url, {
    this.method = 'GET',
    this.headers = '',
    this.keepAlive = true,
    this.requestsPerConn = 1,
    this.interval = 0,
    this.hold = 0,
    this.timeout = 8,
    this.connectTimeout = 8,
    this.nodelay = true,
    this.splitSend = false,
    this.splitDelay = 0,
    this.verifyCerts = false,
    this.body,
  });
  final String url, method, headers;
  final bool keepAlive, nodelay, splitSend, verifyCerts;

  /// Custom payload sent as the request body (Content-Length is filled in automatically).
  final Uint8List? body;
  int requestsPerConn;

  /// timeout: reply wait (0 = forever); connectTimeout: DNS/TCP/proxy/TLS (0 = OS decides)
  final double interval, timeout, connectTimeout, splitDelay;
  double hold;
}

Future<void> _sleep(double s, bool Function() stopped) async {
  final end = now() + s;
  while (now() < end && !stopped()) {
    await Future.delayed(
      Duration(milliseconds: ((end - now()) * 1000).clamp(0, 200).round()),
    );
  }
}

/// [url] overrides [HttpJob.url] for this connection (multi mode with per-connection URLs).
Future<int> runHttpOnSession(
  TcpSession sess,
  HttpJob job,
  bool Function() stopped, {
  String? url,
}) async {
  final u = parseUrl(url ?? job.url);
  var ok = 0;
  for (var i = 0; i < job.requestsPerConn; i++) {
    if (stopped()) break;
    final last = i == job.requestsPerConn - 1;
    final parts = buildHttpRequest(
      job.method,
      u.host,
      u.port,
      u.path,
      extraHeaders: job.headers,
      keepAlive: job.keepAlive || !last,
      scheme: u.scheme,
      body: job.body,
    );
    sess.expectResponse(job.method, u.path);
    if (job.splitSend) {
      const labels = ['TX 请求行', 'TX 请求头', 'TX 空行', 'TX Body'];
      for (var k = 0; k < parts.length; k++) {
        if (parts[k].isEmpty) continue;
        if (!await sess.send(parts[k], label: labels[k])) return ok;
        if (job.splitDelay > 0) await _sleep(job.splitDelay, stopped);
      }
    } else {
      final all = [for (final p in parts) ...p];
      if (!await sess.send(
        Uint8List.fromList(all),
        label: 'TX HTTP 请求 #${i + 1}',
      )) {
        return ok;
      }
    }
    if (await sess.waitResponses(i + 1, job.timeout)) {
      ok++;
      sess.ok = ok; // publish progress so a kept-alive row shows 成功 1 while it is still open
    } else {
      final why = sess.state != 'established'
          ? '连接已断开'
          : '${job.timeout}s 内未收到任何数据(回包超时)';
      sess.emit('err', '请求 #${i + 1} 未完成: $why');
      sess.error ??=
          '请求 #${i + 1} $why'; // shown in the row and counted in the summary
      break;
    }
    if (job.interval > 0 && !last) {
      sess.holding = true;
      await _sleep(job.interval, stopped);
      sess.holding = false;
    }
  }
  return ok;
}

class _Sem {
  _Sem(this._n);
  int _n;
  final Queue<Completer<void>> _q = Queue();
  Future<void> acquire() async {
    if (_n > 0) {
      _n--;
      return;
    }
    final c = Completer<void>();
    _q.add(c);
    await c.future;
  }

  void release() => _q.isNotEmpty ? _q.removeFirst().complete() : _n++;
}

class RowData {
  RowData(this.idx);
  final int idx;
  int cid = 0, ok = 0;
  String url = '';
  String status = '',
      dns = '-',
      tcp = '-',
      proxy = '-',
      ttfb = '-',
      codes = '-',
      tx = '0B',
      rx = '0B',
      speed = '-',
      error = '';
  double uptime = 0, idle = 0;
  List<String> toCsv() => [
    '$idx',
    '$cid',
    url,
    status,
    dns,
    tcp,
    proxy,
    ttfb,
    codes,
    '$ok',
    tx,
    rx,
    speed,
    uptime > 0 ? ms(uptime) : '-',
    idle > 0 ? ms(idle) : '-',
    error,
  ];
  static const csvHeader = [
    '#',
    '连接ID',
    'URL',
    '状态',
    'DNS',
    'TCP握手',
    '代理握手',
    'TTFB',
    '状态码',
    '成功',
    '发送',
    '接收',
    '速度',
    '持续',
    '空闲',
    '错误',
  ];
}

class MultiRunner {
  MultiRunner(
    this.job,
    ProxyConfig proxy,
    this.sink, {
    this.count = 10,
    this.concurrency = 10,
    this.stagger = 0,
    this.verbose = false,
    this.bindRange,
    this.saveDir,
    List<String>? urls,
    this.noTls = false,
  }) : proxy = proxy.copy(),
       urls = urls == null ? null : List<String>.unmodifiable(urls);
  final HttpJob job;

  /// true = send the HTTP request in plain text right after the TCP handshake, even for https:// URLs
  /// (no TLS handshake). The Host header and port stay as in the URL.
  final bool noTls;

  /// Per-connection URLs (index 0 = connection #1). A missing or blank entry uses [HttpJob.url].
  final List<String>? urls;

  String urlFor(int idx) {
    final l = urls;
    final u = l != null && idx >= 1 && idx <= l.length ? l[idx - 1].trim() : '';
    return u.isEmpty ? job.url : u;
  }

  final ProxyConfig proxy;
  final EventSink sink;
  final int count, concurrency;
  final double stagger;
  final bool verbose;
  final (int, int)? bindRange;
  final String? saveDir;
  final List<TcpSession> sessions = [];
  bool _stop = false;
  bool running = false;
  Map<String, Object?>? summary;
  final _done = Completer<void>();
  final Map<int, String> _invalidConnections = {};
  Timer? _ticker;
  Future<void> get done => _done.future;

  bool get stopped => _stop;

  void start() {
    if (running || _done.isCompleted) return;
    running = true;
    _run();
  }

  void cancel() {
    _stop = true;
    _ticker?.cancel();
    _ticker = null;
    for (final s in [...sessions]) {
      s.close();
    }
  }

  void _row(int idx, TcpSession s, String status) {
    final st = s.stats;
    String f(String k) => st.containsKey(k) ? ms(st[k]!) : '-';
    final live = s.passive();
    final cur = s.parser.cur;
    final nbytes = s.bodyBytes + (cur?.bodyLen ?? 0);
    final secs = s.bodyTime + (cur != null ? now() - cur.tHead : 0);
    final r = RowData(idx)
      ..cid = s.cid
      ..url = urlFor(idx)
      ..status = status
      ..dns = f('dns')
      ..tcp = f('tcp')
      ..proxy = f('proxy')
      ..ttfb = f('ttfb')
      ..codes = s.parser.done.isEmpty
          ? '-'
          : s.parser.done.map((x) => x.code).join(',')
      ..ok = s.ok
      ..tx = fmtSize(s.txBytes)
      ..rx = fmtSize(s.rxBytes)
      ..speed = nbytes > 0 ? fmtSpeed(nbytes, secs) : '-'
      ..uptime = live.up
      ..idle = live.idle
      ..error = s.error ?? '';
    sink(Ev(s.cid, 'row', '', r));
  }

  Future<void> _worker(int idx, _Sem sem) async {
    var released = false;
    void releaseSlot() {
      if (released) return;
      released = true;
      sem.release();
    }

    TcpSession? session;
    var status = '失败';
    try {
      if (_stop) return;
      final url = urlFor(idx);
      final u = parseUrl(url);
      final s = TcpSession(
        u.host,
        u.port,
        proxy,
        sink,
        timeout: job.timeout,
        connectTimeout: job.connectTimeout,
        nodelay: job.nodelay,
        useTls: u.scheme == 'https' && !noTls,
        verbose: verbose,
        bindRange: bindRange,
        verifyCerts: job.verifyCerts,
      );
      session = s;
      if (noTls && u.scheme == 'https') {
        s.emit('info', '不做 TLS 握手：TCP 握手后直接发送明文请求（$url）');
      }
      if (saveDir != null) {
        s.setSave(saveDir, unique: count > 1 || job.requestsPerConn > 1);
      }
      sessions.add(s);
      s.rowIdx = idx;
      s.onProgress = (x) => _row(idx, x, '传输中');
      _row(idx, s, '连接中');
      if (!await s.connect()) {
        status = _stop ? '已取消' : '失败';
        return;
      }
      _row(idx, s, '已建立');
      s.ok = await runHttpOnSession(s, job, () => _stop, url: url);
      s.tRequestsDone = now();
      // Requests are over: idle holding must not occupy a concurrency slot or
      // count towards transfer time. Hold exactly once, for single and multi.
      releaseSlot();
      var peerClosed = false;
      final allOk = s.ok == job.requestsPerConn;
      final hold = job.hold > 0
          ? job.hold
          : (job.keepAlive && count > 1 ? double.infinity : 0.0);
      if (s.state == 'established' && allOk && !_stop && hold > 0) {
        s.emit('info', hold.isFinite ? '保持连接 ${hold}s' : '保持连接，直到停止或对端关闭');
        s.holding = true;
        await _sleep(hold, () => _stop || s.state != 'established');
        s.holding = false;
        peerClosed = s.state == 'closed' && !_stop;
      }
      final want = job.requestsPerConn;
      status = peerClosed
          ? '对端断开'
          : (_stop && s.ok < want
                ? '已取消'
                : (s.ok == want
                      ? (want == 0 ? '已建立' : '完成')
                      : (s.ok > 0 ? '部分' : '无响应')));
    } catch (e) {
      final message = '连接 #$idx 异常: $e';
      if (session == null) {
        _invalidConnections[idx] = '$e';
        sink(
          Ev(
            0,
            'row',
            '',
            RowData(idx)
              ..url = urlFor(idx)
              ..status = '失败'
              ..error = '$e',
          ),
        );
      } else {
        session.error ??= '$e';
      }
      sink(Ev(session?.cid ?? 0, 'err', message));
    } finally {
      releaseSlot();
      final s = session;
      if (s != null) {
        if (s.state == 'established' || s.state == 'connecting') s.close();
        await s.flushFiles();
        s.onProgress = null;
        if (s.saveErrors > 0 && status == '完成') status = '保存失败';
        _row(idx, s, status);
      }
    }
  }

  /// Live table refresh for open connections. Purely passive: reads state that the
  /// receive path already recorded, never writes to the socket.
  void _startTicker() {
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      for (final s in List<TcpSession>.of(sessions)) {
        if (s.state != 'established') continue;
        final live = s.passive();
        _row(s.rowIdx, s, live.state);
      }
    });
  }

  Future<void> _run() async {
    final t0 = now();
    _startTicker();
    final sem = _Sem(concurrency < 1 ? 1 : concurrency);
    final workers = <Future<void>>[];
    for (var i = 0; i < count; i++) {
      if (_stop) break;
      await sem.acquire();
      if (_stop) {
        sem.release();
        break;
      }
      workers.add(_worker(i + 1, sem));
      if (stagger > 0) await _sleep(stagger, () => _stop);
    }
    await Future.wait(workers);
    _ticker?.cancel();
    _ticker = null;
    for (final s in sessions) {
      if (s.state == 'established') s.close();
    }
    summary = summarize(now() - t0);
    running = false;
    sink(Ev(0, 'done', summary!['text'] as String, summary));
    _done.complete();
  }

  Map<String, Object?> summarize(double wall) {
    final ss = sessions;
    final want = job.requestsPerConn;
    final connOk = ss.where((s) => s.stats.containsKey('tcp')).length;
    final full = ss
        .where((s) => s.ok == want && s.stats.containsKey('tcp'))
        .length;
    final body = ss.fold<int>(0, (a, s) => a + s.bodyBytes);
    // Throughput covers the transfer phase only: from the first connect to the last
    // request finishing. Idle keep-alive holding afterwards is not transfer time.
    final starts = [
      for (final s in ss)
        if (s.t0 > 0) s.t0,
    ];
    final ends = [
      for (final s in ss)
        if (s.tRequestsDone > 0) s.tRequestsDone,
    ];
    final xfer = starts.isNotEmpty && ends.isNotEmpty
        ? ends.reduce((a, b) => a > b ? a : b) -
              starts.reduce((a, b) => a < b ? a : b)
        : wall;
    Map<String, double>? dist(String k) {
      final v = [
        for (final s in ss)
          if (s.stats.containsKey(k)) s.stats[k]!,
      ];
      if (v.isEmpty) return null;
      return {
        'avg': v.reduce((a, b) => a + b) / v.length,
        'p50': percentile(v, 50)!,
        'p95': percentile(v, 95)!,
        'max': v.reduce((a, b) => a > b ? a : b),
      };
    }

    String ds(Map<String, double>? d) => d == null
        ? '-'
        : d.entries.map((e) => '${e.key}=${ms(e.value)}').join(' ');
    final tcp = dist('tcp'), ttfb = dist('ttfb'), prx = dist('proxy');
    final total = ss.length + _invalidConnections.length;
    final n = total == 0 ? 1 : total;
    final saveErrors = ss.fold<int>(0, (n, s) => n + s.saveErrors);
    final lines = [
      '批量完成：$total 个连接，建连成功 $connOk (${(connOk * 100 / n).toStringAsFixed(1)}%)，'
          '请求全部成功 $full (${(full * 100 / n).toStringAsFixed(1)}%)，总耗时 ${ms(wall)}',
      '    TCP 握手: ${ds(tcp)}',
      if (prx != null) '    代理握手: ${ds(prx)}',
      '    TTFB    : ${ds(ttfb)}',
      '    正文合计 ${fmtSize(body)}，整体吞吐 ${fmtSpeed(body, xfer)}'
          '${xfer < wall - 0.5 ? '（传输 ${ms(xfer)}，其余为 keep-alive 保持时间）' : ''}',
    ];
    final errs = <String, int>{};
    for (final error in _invalidConnections.values) {
      errs[error] = (errs[error] ?? 0) + 1;
    }
    for (final s in ss) {
      if (s.error != null) errs[s.error!] = (errs[s.error!] ?? 0) + 1;
    }
    if (total < count) lines.add('    计划 $count 个连接，未启动 ${count - total} 个');
    if (saveErrors > 0) lines.add('    保存失败 $saveErrors 次（HTTP 收包成功与写盘结果分别统计）');
    final top = errs.entries.toList()..sort((a, b) => b.value - a.value);
    for (final e in top.take(5)) {
      lines.add('    错误 x${e.value}: ${e.key}');
    }
    return {
      'text': lines.join('\n'),
      'total': total,
      'planned': count,
      'unstarted': count - total,
      'stopped': _stop,
      'saveErrors': saveErrors,
      'connOk': connOk,
      'fullOk': full,
      'wall': wall,
      'body': body,
      'tcp': tcp,
      'ttfb': ttfb,
      'proxy': prx,
      'errors': errs,
      'short':
          '$full/$total 成功，TCP p50=${tcp != null ? ms(tcp['p50']!) : '-'}，'
          'TTFB p50=${ttfb != null ? ms(ttfb['p50']!) : '-'}，吞吐 ${fmtSpeed(body, xfer)}',
    };
  }
}
