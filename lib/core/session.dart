// One TCP connection: connect (direct / SOCKS5 / HTTP CONNECT), optional TLS (auto or manual step-by-step),
// HTTP send/receive with streaming download to disk. All activity is reported as [Ev] events.
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'http.dart';
import 'platform.dart';
import 'proxy.dart';
import 'tls_view.dart';
import 'util.dart';

class Ev {
  Ev(this.cid, this.kind, this.msg, [this.data]) : t = DateTime.now();
  Ev.metadata(Ev event)
    : t = event.t,
      cid = event.cid,
      kind = event.kind,
      msg = event.msg,
      data = null;
  final DateTime t;
  final int cid;
  final String kind; // info state tx rx http err close tls row done
  final String msg;
  final Object? data;
}

typedef EventSink = void Function(Ev e);

int _nextId = 1;
final Set<String> _activeDownloads = {};
const rxLogQuota = 30;
const progressEvery = 1.0;

class PortAllocator {
  int? _next;
  int take(int lo, int hi) {
    if (_next == null || _next! < lo || _next! > hi) _next = lo;
    final p = _next!;
    _next = p >= hi ? lo : p + 1;
    return p;
  }

  set next(int v) => _next = v;
}

final ports = PortAllocator();

class _Waiter {
  _Waiter(this.n);
  final int n;
  final c = Completer<bool>();
}

class TcpSession implements HandshakeIO {
  TcpSession(
    this.host,
    this.port,
    ProxyConfig proxy,
    this.sink, {
    this.timeout = 8,
    this.connectTimeout = 8,
    this.nodelay = true,
    this.useTls = false,
    this.verbose = true,
    this.bindRange,
    this.verifyCerts = false,
  }) : proxy = proxy.copy(),
       cid = _nextId++ {
    parser.onHead = _onHead;
    parser.onBody = _onBody;
  }

  final int cid;
  final String host;
  final int port;
  ProxyConfig proxy;
  final EventSink sink;

  /// Waiting for a reply: give up after this many seconds with no data at all. 0 = wait forever.
  final double timeout;

  /// DNS / TCP handshake / proxy / TLS. 0 = no app limit (the OS decides after its SYN retries).
  final double connectTimeout;
  final bool nodelay, useTls, verbose;
  final (int, int)? bindRange;

  /// false = accept self-signed / expired / hostname-mismatched certificates (default).
  final bool verifyCerts;

  RawSocket? sock;
  String state = 'init';
  final parser = HttpResponseParser();
  final Map<String, double> stats = {};
  String? error;
  int txBytes = 0, rxBytes = 0, ok = 0;
  int rowIdx = 0; // table row this session belongs to (set by the runner)
  bool holding = false; // inside the post-request keep-alive hold window
  double tRequestsDone =
      0; // when this connection finished its request loop (0 = not yet)
  double t0 = 0;
  double? tLastTx, tLastRx;
  bool _awaitRx = false, _closing = false;
  int rxQuota = rxLogQuota;
  double _progT = 0;
  int bodyBytes = 0, saveErrors = 0;
  double bodyTime = 0;
  String? saveDir;
  bool saveUnique = false;
  void Function(TcpSession s)? onProgress;
  final List<_Waiter> _waiters = [];
  final List<Future<void>> _fileOps = [];
  StreamSubscription<RawSocketEvent>? _sub;
  final Set<ConnectionTask<RawSocket>> _pendingConnects = {};
  final Completer<void> _cancelled = Completer<void>();

  Duration? get _connectDur => connectTimeout > 0
      ? Duration(milliseconds: (connectTimeout * 1000).round())
      : null;

  void _checkCancelled() {
    if (_closing) throw const SocketException('已取消');
  }

  Future<T> _limit<T>(Future<T> f, String what) {
    final cancellable = Future.any<T>([
      f,
      _cancelled.future.then<T>((_) => throw const SocketException('已取消')),
    ]);
    final d = _connectDur;
    if (d == null) return cancellable;
    return cancellable.timeout(
      d,
      onTimeout: () => throw SocketException('$what超时 (${connectTimeout}s)'),
    );
  }

  // handshake reader buffer (proxy phase)
  bool _hsPhase = false;
  final BytesBuilder _hsBuf = BytesBuilder(copy: true);
  Completer<void>? _hsWait;

  // write queue
  final Queue<(Uint8List, Completer<bool>)> _wq = Queue();
  bool _writing = false;
  Completer<void>? _writable;

  // manual TLS
  int? tlsId;

  /// Set when the TLS session is closed; decrypts still queued behind it are dropped quietly.
  bool _tlsClosed = false;
  bool tlsDone = false, tlsPlain = false, _tlsSentHello = false;
  String? lastTlsError;
  bool tlsFailed = false;
  int _tlsRx = 0;
  final BytesBuilder _tlsPending = BytesBuilder(copy: true);
  Future<void> _tlsChain = Future.value();
  TlsRecordView? txView, rxView;

  void emit(String kind, String msg, {Object? data, bool force = false}) {
    if (verbose ||
        force ||
        kind == 'err' ||
        kind == 'state' ||
        kind == 'close') {
      sink(Ev(cid, kind, msg, data));
    }
  }

  /// Purely passive view of this connection: nothing is written to the socket and no
  /// probe is sent. State comes from the events we already receive (data / FIN / RST).
  ({String state, double up, double idle, bool open}) passive() {
    final end = state == 'closed' && stats.containsKey('duration')
        ? t0 + stats['duration']!
        : now();
    final up = end - t0;
    final idle = end - (tLastRx ?? tLastTx ?? t0);
    String st;
    switch (state) {
      case 'connecting':
      case 'init':
        st = '连接中';
      case 'established':
        st = parser.cur != null ? '接收中' : (holding ? '保持中' : '已建立');
      case 'closed':
        st = _closing ? '已关闭' : '已断开';
      case 'failed':
        st = '失败';
      default:
        st = state;
    }
    return (state: st, up: up, idle: idle, open: state == 'established');
  }

  void setSave(String? dir, {bool unique = false}) {
    saveDir = dir;
    saveUnique = unique;
  }

  // ---------------------------------------------------------------- connect
  Future<bool> connect() async {
    if (_closing) return false;
    t0 = now();
    state = 'connecting';
    try {
      proxy = await _limit(proxy.resolved(), '系统代理解析');
      _checkCancelled();
      final p = proxy;
      final dstHost = p.mode == 'direct' ? host : p.host;
      final dstPort = p.mode == 'direct' ? port : p.port;
      final dnsStart = now();
      final addrs = await _limit(InternetAddress.lookup(dstHost), 'DNS 解析');
      _checkCancelled();
      if (addrs.isEmpty) throw SocketException('DNS 未返回可用地址: $dstHost');
      if (p.mode == 'direct') {
        stats['dns'] = now() - dnsStart;
        emit(
          'info',
          'DNS $host -> ${addrs.map((a) => a.address + ipNote(a.address)).join(', ')} 用时 ${ms(stats['dns']!)}',
        );
      } else {
        emit('info', '经代理 ${p.describe()} 连接 $host:$port');
      }
      final t = await _open(addrs, dstPort);
      _checkCancelled();
      stats['tcp'] = now() - t;
      final s = sock!;
      if (nodelay) s.setOption(SocketOption.tcpNoDelay, true);
      _applyUserTimeout(s);
      var local = '';
      try {
        local = ' 本地端口 ${s.port}';
      } catch (_) {}
      emit(
        'state',
        'TCP 已建立 (三次握手 ${ms(stats['tcp']!)})$local -> ${s.remoteAddress.address}:$dstPort',
      );
      _hsPhase = true;
      _sub = s.listen(
        _onEvent,
        onError: (Object e) => _finish('读取错误: $e'),
        cancelOnError: true,
      );
      if (p.mode == 'socks5' || p.mode == 'http') {
        final t2 = now();
        if (p.mode == 'socks5') {
          var target = host;
          if (!p.remoteDns) {
            target = (await _limit(
              InternetAddress.lookup(host),
              '目标 DNS 解析',
            )).first.address;
            _checkCancelled();
          }
          await _limit(
            socks5Handshake(this, target, port, p.user, p.password),
            '代理握手',
          );
        } else {
          await _limit(
            httpConnectHandshake(this, host, port, p.user, p.password),
            '代理握手',
          );
        }
        _checkCancelled();
        stats['proxy'] = now() - t2;
        emit('state', '代理隧道已建立 ${ms(stats['proxy']!)}');
      }
      final left = _hsBuf.takeBytes();
      _hsPhase = false;
      if (useTls) await _autoTls(left.isNotEmpty);
      _checkCancelled();
      if (state == 'closed') throw const SocketException('对端在建连过程中关闭连接');
      state = 'established';
      if (left.isNotEmpty) _onData(left);
      return true;
    } catch (e) {
      error = _closing
          ? '已取消'
          : e is SocketException
          ? '${e.message}${e.osError != null ? ' (${e.osError})' : ''}'
          : '$e';
      if (!_closing) {
        state = 'failed';
        emit('err', '连接失败: $error (已用 ${ms(now() - t0)})');
      }
      for (final task in _pendingConnects.toList()) {
        task.cancel();
      }
      try {
        sock?.close();
      } catch (_) {}
      return false;
    }
  }

  /// Race resolved addresses with a short stagger, keeping one timeout for the
  /// whole TCP phase. A black-holed IPv6 address must not hide a working IPv4 one.
  Future<double> _open(List<InternetAddress> addresses, int port) async {
    final started = now();
    final result = Completer<RawSocket>();
    final tasks = <ConnectionTask<RawSocket>>{};
    var next = 0, active = 0;
    var finished = false, adopted = false;
    RawSocket? selected;
    Timer? fallback;
    final tries = bindRange == null
        ? 1
        : (bindRange!.$2 - bindRange!.$1 + 1).clamp(1, 64);

    Future<RawSocket> attempt(InternetAddress address) async {
      Object? last;
      for (var i = 0; i < tries; i++) {
        _checkCancelled();
        if (finished) throw const SocketException('已结束建连');
        final lp = bindRange == null
            ? 0
            : ports.take(bindRange!.$1, bindRange!.$2);
        emit(
          'state',
          'SYN -> ${address.address}:$port${lp == 0 ? '' : ' (本地端口 $lp)'}',
        );
        ConnectionTask<RawSocket>? task;
        try {
          task = await RawSocket.startConnect(address, port, sourcePort: lp);
          tasks.add(task);
          _pendingConnects.add(task);
          final socketFuture = task.socket;
          if (_closing || finished) task.cancel();
          final socket = await socketFuture;
          if (_closing || finished) {
            socket.close();
            throw const SocketException('已取消');
          }
          return socket;
        } on SocketException catch (e) {
          if (_closing || finished) rethrow;
          final code = e.osError?.errorCode;
          if (code == 110 || code == 10060) {
            throw SocketException(
              '系统放弃连接：多次重传 SYN 仍未收到 SYN-ACK（用时 ${(now() - started).toStringAsFixed(1)}s）',
              osError: e.osError,
            );
          }
          final busy = const [
            98,
            99,
            10048,
            10049,
            10057,
            48,
            49,
          ].contains(code);
          if (lp == 0 || !busy) rethrow;
          last = e;
          emit('info', '本地端口 $lp 不可用，换下一个');
        } finally {
          if (task != null) {
            tasks.remove(task);
            _pendingConnects.remove(task);
          }
        }
      }
      throw SocketException(
        '端口段 ${bindRange!.$1}-${bindRange!.$2} 连续 $tries 个端口不可用: $last',
      );
    }

    void launch() {
      if (finished ||
          _closing ||
          result.isCompleted ||
          next >= addresses.length) {
        return;
      }
      fallback?.cancel();
      final address = addresses[next++];
      active++;
      attempt(address).then(
        (socket) {
          active--;
          if (finished || _closing || result.isCompleted) {
            socket.close();
          } else {
            selected = socket;
            result.complete(socket);
          }
        },
        onError: (Object e, StackTrace st) {
          active--;
          if (finished || result.isCompleted) return;
          if (next < addresses.length) {
            launch();
          } else if (active == 0) {
            result.completeError(e, st);
          }
        },
      );
      if (next < addresses.length) {
        fallback = Timer(const Duration(milliseconds: 250), launch);
      }
    }

    final notice = Timer.periodic(
      const Duration(seconds: 5),
      (_) => emit(
        'info',
        '等待 SYN-ACK… 已等待 ${(now() - started).toStringAsFixed(0)}s（系统按协议自动重传 SYN，本程序不发探测包）',
      ),
    );
    try {
      launch();
      final socket = await _limit(result.future, '连接');
      _checkCancelled();
      sock = socket;
      adopted = true;
      return started;
    } finally {
      finished = true;
      if (!adopted) selected?.close();
      fallback?.cancel();
      notice.cancel();
      for (final task in tasks.toList()) {
        task.cancel();
      }
    }
  }

  Future<void> _autoTls(bool hadLeftover) async {
    final t = now();
    final secure = RawSecureSocket.secure(
      sock!,
      subscription: _sub,
      host: host,
      supportedProtocols: ['http/1.1'],
      onBadCertificate: (cert) {
        final ok = verifyCerts;
        emit(
          ok ? 'err' : 'info',
          '${ok ? '证书校验失败' : '已接受不被信任的证书'} subject=${cert.subject} issuer=${cert.issuer}'
          ' 有效期 ${cert.startValidity} ~ ${cert.endValidity}',
          force: true,
        );
        return !ok;
      },
    );
    // A secure socket can complete after cancellation/timeout; never leak it.
    secure.then((s) {
      if (_closing || state == 'failed' || state == 'closed') s.close();
    }, onError: (Object _, StackTrace _) {});
    final secure2 = await _limit(secure, 'TLS 握手');
    _checkCancelled();
    sock = secure2;
    _sub = secure2.listen(
      _onEvent,
      onError: (Object e) => _finish('TLS 错误: $e'),
      cancelOnError: true,
    );
    stats['tls'] = now() - t;
    emit(
      'state',
      'TLS 握手完成 ${ms(stats['tls']!)} ALPN=${secure2.selectedProtocol ?? '-'}',
    );
  }

  // ---------------------------------------------------------------- HandshakeIO (proxy phase)
  @override
  Future<Uint8List> readExact(int n) async {
    while (_hsBuf.length < n) {
      if (state == 'closed') throw const SocketException('代理提前关闭连接');
      _hsWait = Completer();
      await _hsWait!.future;
    }
    final all = _hsBuf.takeBytes();
    _hsBuf.add(Uint8List.sublistView(all, n));
    return Uint8List.fromList(all.sublist(0, n));
  }

  @override
  Future<Uint8List> readUntil(List<int> delim, {int max = 65536}) async {
    while (true) {
      final cur = _hsBuf.toBytes();
      final i = indexOf(cur, delim);
      if (i >= 0) return readExact(i + delim.length);
      if (cur.length > max) throw const SocketException('代理响应头过大');
      if (state == 'closed') throw const SocketException('代理提前关闭连接');
      _hsWait = Completer();
      await _hsWait!.future;
    }
  }

  @override
  Future<void> write(List<int> data) async {
    if (!await _rawWrite(Uint8List.fromList(data))) {
      throw const SocketException('写入失败');
    }
  }

  // ---------------------------------------------------------------- socket events
  void _onEvent(RawSocketEvent ev) {
    final s = sock;
    if (s == null) return;
    switch (ev) {
      case RawSocketEvent.read:
        while (s.available() > 0) {
          final d = s.read();
          if (d == null || d.isEmpty) break;
          if (_hsPhase) {
            _hsBuf.add(d);
            _hsWait?.complete();
            _hsWait = null;
          } else {
            _onData(d);
          }
        }
      case RawSocketEvent.write:
        _writable?.complete();
        _writable = null;
      case RawSocketEvent.readClosed:
        _finishAfterTls(_closing ? '本地关闭' : '对端关闭 (收到 FIN)');
      case RawSocketEvent.closed:
        _finishAfterTls(_closing ? '本地关闭' : '连接已关闭');
    }
  }

  /// With manual TLS, ciphertext received before FIN may still be decrypting; finish after it.
  void _finishAfterTls(String reason) {
    if (tlsId != null && tlsDone) {
      _tlsChain.then((_) => _finish(reason));
    } else {
      _finish(reason);
    }
  }

  void _finish(String reason) {
    if (state == 'closed') return;
    final wasTlsPending = tlsId != null && !tlsDone;
    state = 'closed';
    _hsWait?.complete();
    _hsWait = null;
    _writable?.complete();
    _writable = null;
    try {
      final r = parser.onEof();
      for (final x in r.finished) {
        _onResponse(x);
      }
      if (r.cut != null) _onResponse(r.cut!);
    } catch (e) {
      emit('err', '收尾出错: $e');
    }
    stats['duration'] = now() - t0;
    if (wasTlsPending) reason += '；TLS 握手未完成';
    emit('close', '$reason；共发送 ${txBytes}B 接收 ${rxBytes}B');
    if (tlsId != null) {
      _tlsClosed = true;
      Native.tlsClose(tlsId!);
    }
    _notify();
    try {
      sock?.close();
    } catch (_) {}
  }

  void _onData(Uint8List data) {
    final t = now();
    if (_awaitRx && tLastTx != null) {
      _awaitRx = false;
      stats.putIfAbsent('ttfb', () => t - tLastTx!);
      emit('info', '首字节 TTFB ${ms(t - tLastTx!)}');
    }
    rxBytes += data.length;
    tLastRx = t;
    if (tlsId != null && !tlsPlain) {
      if (!tlsDone && _tlsRx == 0 && !tlsCt.containsKey(data[0])) {
        tlsPlain = true;
        final head = String.fromCharCodes(
          data.take(80).takeWhile((c) => c != 13),
        );
        emit(
          'err',
          '对端回的不是 TLS 记录，该端口很可能不是 TLS 服务（首行: $head），以下按明文解析',
          force: true,
        );
      } else {
        _tlsRx += data.length;
        _rxLog('rx', 'RX TLS 密文 ${data.length}B', data);
        _tlsFeed(data);
        return;
      }
    }
    _rxLog('rx', 'RX ${data.length}B', data);
    _parse(data);
  }

  void _parse(Uint8List data) {
    try {
      for (final r in parser.feed(data)) {
        _onResponse(r);
      }
    } catch (e) {
      emit('err', 'HTTP 解析失败: $e');
    }
  }

  void _rxLog(String kind, String msg, [Uint8List? data, bool force = false]) {
    if (rxQuota > 0) {
      rxQuota--;
      emit(kind, msg, data: data, force: force);
      if (rxQuota == 0) {
        emit('info', '接收数据较多，后续 RX 明细不再逐条显示，改为显示进度', force: force);
      }
    }
  }

  // ---------------------------------------------------------------- HTTP response hooks
  void _saveFailed(HttpResp r, Object e) {
    if (r.saveFailed) return;
    r.saveFailed = true;
    saveErrors++;
    error ??= '保存失败: $e';
    emit('err', '保存失败: $e', force: true);
  }

  void _onHead(HttpResp r) {
    r.n = parser.done.length + 1;
    emit(
      'http',
      '响应头 #${r.n}: ${r.status}  正文大小 ${r.total != null ? fmtSize(r.total!) : '未知'}',
      force: true,
    );
    _progT = now();
    if (saveDir != null) {
      try {
        Directory(saveDir!).createSync(recursive: true);
        String pathFor(String suffix) =>
            '$saveDir${Platform.pathSeparator}${targetName(r.path, suffix)}';
        String keyFor(String file) => Platform.isWindows
            ? File(file).absolute.path.toLowerCase()
            : File(file).absolute.path;
        var f = pathFor(saveUnique ? '_c${cid}_r${r.n}' : '');
        if (_activeDownloads.contains(keyFor(f))) {
          var extra = 0;
          do {
            f = pathFor('_c${cid}_r${r.n}${extra == 0 ? '' : '_$extra'}');
            extra++;
          } while (_activeDownloads.contains(keyFor(f)) ||
              File(f).existsSync());
        }
        r.file = f;
        r.saveKey = keyFor(f);
        _activeDownloads.add(r.saveKey!);
        // Even a single request can run beside another page's request. Never share
        // a partially written file; only the final filename follows curl -O.
        r.tempFile = '$f.c${cid}_r${r.n}.part';
        final download = File(r.tempFile!).openWrite();
        r.sink = download;
        // openWrite/add fail asynchronously. Attach a handler now, not at EOF.
        r.sinkDone = download.done.then<void>(
          (_) {},
          onError: (Object e, StackTrace st) {
            _saveFailed(r, e);
          },
        );
        // Start the consumer immediately. Otherwise file.open's error can occur
        // before the first body byte attaches the IOSink's internal listener.
        download.add(const <int>[]);
      } catch (e) {
        if (r.saveKey != null) _activeDownloads.remove(r.saveKey);
        _saveFailed(r, e);
      }
    }
  }

  void _onBody(HttpResp r, Uint8List d) {
    if (!r.saveFailed) {
      try {
        r.sink?.add(d);
      } catch (e) {
        _saveFailed(r, e);
      }
    }
    final t = now();
    if (t - _progT >= progressEvery) {
      _progT = t;
      final el = t - r.tHead;
      final pct = r.total != null && r.total! > 0
          ? ' ${(r.bodyLen * 100 / r.total!).toStringAsFixed(1)}%'
          : '';
      final tot = r.total != null ? '/${fmtSize(r.total!)}' : '';
      emit(
        'info',
        '下载中 ${fmtSize(r.bodyLen)}$tot$pct  ${fmtSpeed(r.bodyLen, el)}',
      );
      onProgress?.call(this);
    }
  }

  void _onResponse(HttpResp r) {
    if (r.n == 0) r.n = parser.done.length;
    final el = r.tEnd - r.tHead;
    bodyBytes += r.bodyLen;
    bodyTime += el;
    final tag = r.incomplete ? '  ⚠ 连接中断，正文不完整' : '';
    emit(
      r.incomplete ? 'err' : 'http',
      'HTTP 响应 #${r.n}: ${r.status} 正文 ${fmtSize(r.bodyLen)} 用时 ${ms(el)} 平均 ${fmtSpeed(r.bodyLen, el)}$tag',
      force: true,
    );
    if (r.sink != null) {
      final sinkRef = r.sink!, file = r.file!, temp = r.tempFile!;
      r.sink = null;
      _fileOps.add(() async {
        try {
          await sinkRef.close();
          await r.sinkDone;
          if (r.saveFailed) return;
          final fin = file + (r.incomplete ? '.incomplete' : '');
          // rename replaces an existing final file without first deleting it.
          // Concurrent active downloads have already reserved distinct names.
          await File(temp).rename(fin);
          emit('http', '已保存 ${fmtSize(r.bodyLen)} -> $fin', force: true);
        } catch (e) {
          _saveFailed(r, e);
        } finally {
          if (r.saveKey != null) _activeDownloads.remove(r.saveKey);
        }
      }());
    }
    rxQuota = rxLogQuota;
    onProgress?.call(this);
    _notify();
  }

  void _notify() {
    _waiters.removeWhere((w) {
      if (parser.done.length >= w.n || state != 'established') {
        w.c.complete(parser.done.length >= w.n);
        return true;
      }
      return false;
    });
  }

  /// Waits until [n] responses are complete. Fails only after [idle] seconds with no data at all.
  Future<bool> waitResponses(int n, double idle) async {
    if (parser.done.length >= n) {
      await Future.wait(_fileOps);
      return true;
    }
    if (state != 'established') return false;
    final w = _Waiter(n);
    _waiters.add(w);
    final start = now();
    var nextNotice = start + 10;
    final timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final last = [
        start,
        tLastRx ?? 0,
        tLastTx ?? 0,
      ].reduce((a, b) => a > b ? a : b);
      if (idle > 0 && now() - last > idle && !w.c.isCompleted) {
        _waiters.remove(w);
        w.c.complete(false);
        return;
      }
      if (now() >= nextNotice && !w.c.isCompleted) {
        nextNotice = now() + 10;
        emit(
          'info',
          '等待回包中… 已 ${(now() - last).toStringAsFixed(0)}s 无数据'
              '${idle > 0 ? '（${idle}s 后判定超时）' : '（不限时，连接保持，不发探测包）'}',
        );
      }
    });
    final ok = await w.c.future;
    timer.cancel();
    await Future.wait(_fileOps);
    return ok;
  }

  Future<void> flushFiles() => Future.wait(_fileOps);

  void expectResponse(String method, String path) {
    parser.expectNoBody.add(method.toUpperCase() == 'HEAD');
    parser.expectPaths.add(path);
  }

  // ---------------------------------------------------------------- writing
  Future<bool> _rawWrite(Uint8List data) {
    final c = Completer<bool>();
    _wq.add((data, c));
    _pump();
    return c.future;
  }

  Future<void> _pump() async {
    if (_writing) return;
    _writing = true;
    try {
      while (_wq.isNotEmpty) {
        final (data, c) = _wq.removeFirst();
        var off = 0;
        var okw = true;
        while (off < data.length) {
          if (state == 'closed' || sock == null) {
            okw = false;
            break;
          }
          int n;
          try {
            n = sock!.write(data, off);
          } catch (e) {
            emit('err', '发送失败: $e');
            okw = false;
            break;
          }
          off += n;
          if (off < data.length) {
            _writable = Completer();
            sock!.writeEventsEnabled = true;
            await _writable!.future;
          }
        }
        c.complete(okw);
      }
    } finally {
      _writing = false;
    }
  }

  /// Send bytes. With manual TLS active and raw == false, data is encrypted first.
  Future<bool> send(
    Uint8List data, {
    String label = 'TX',
    bool raw = false,
  }) async {
    if (sock == null || state != 'established') {
      emit('err', '未连接，无法发送');
      return false;
    }
    var wire = data;
    if (tlsId != null && !raw) {
      if (!tlsDone) {
        emit('err', 'TLS 握手未完成，请先完成 ②③');
        return false;
      }
      final r = await Native.tlsEncrypt(tlsId!, data);
      if (r.error != null) {
        emit('err', 'TLS 加密失败: ${r.error}');
        return false;
      }
      wire = r.out;
      label = '$label 明文 ${data.length}B → TLS 密文';
    }
    if (!await _rawWrite(wire)) return false;
    txBytes += wire.length;
    tLastTx = now();
    _awaitRx = true;
    emit('tx', '$label ${wire.length}B', data: data);
    if (tlsId != null && raw && txView != null) {
      for (final d in txView!.feed(wire)) {
        emit('tls', 'TLS → $d', force: true);
      }
    }
    return true;
  }

  Future<bool> sendChunked(
    Uint8List data,
    int size,
    double delay, {
    bool Function()? stopped,
    bool raw = false,
    String label = 'TX 分片',
  }) async {
    size = size < 1 ? 1 : size;
    for (var i = 0; i < data.length; i += size) {
      if (stopped?.call() ?? false) return false;
      final end = i + size > data.length ? data.length : i + size;
      if (!await send(
        Uint8List.sublistView(data, i, end),
        label: '$label[${i ~/ size + 1}]',
        raw: raw,
      )) {
        return false;
      }
      if (delay > 0 && end < data.length) {
        final elapsed = Completer<void>();
        final timer = Timer(
          Duration(milliseconds: (delay * 1000).round()),
          elapsed.complete,
        );
        try {
          await Future.any<void>([elapsed.future, _cancelled.future]);
        } finally {
          timer.cancel();
        }
      }
    }
    return true;
  }

  // ---------------------------------------------------------------- manual TLS (Android SSLEngine)
  Future<void> tlsBegin(String sni, {bool? verify, String alpn = ''}) async {
    verify ??= verifyCerts;
    final protos = alpn
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final id = await Native.tlsBegin(host, port, sni, verify, protos);
    if (_closing || state != 'established') {
      await Native.tlsClose(id);
      throw const SocketException('连接已关闭，已取消 TLS 初始化');
    }
    tlsId = id;
    lastTlsError = null;
    tlsDone = tlsPlain = _tlsSentHello = tlsFailed = false;
    _tlsRx = 0;
    txView = TlsRecordView();
    rxView = TlsRecordView();
    final isIp = InternetAddress.tryParse(sni) != null;
    emit(
      'info',
      'TLS 准备就绪 SNI=${isIp ? '不发送(目标是 IP $sni，证书需含该 IP)' : (sni.isEmpty ? '-' : sni)} '
          '校验证书=$verify ALPN=${protos.isEmpty ? '-' : protos.join(',')}',
    );
  }

  void _tlsFeed(Uint8List data) {
    for (final d in rxView!.feed(data)) {
      if (tlsDone) {
        _rxLog('tls', 'TLS ← $d', null, true);
      } else {
        emit('tls', 'TLS ← $d', force: true);
      }
    }
    if (!tlsDone) {
      _tlsPending.add(data);
      emit('info', '握手数据已缓存，点击 ③ 继续握手 处理', force: true);
      return;
    }
    final id = tlsId!;
    _tlsChain = _tlsChain.then((_) async {
      if (_tlsClosed) {
        return; // data that raced the close: the session is already gone
      }
      final r = await Native.tlsDecrypt(id, data);
      if (r.error != null) emit('err', 'TLS 解密失败: ${r.error}');
      if (r.closed) emit('state', '收到 TLS close_notify');
      _onPlain(r.plain);
    });
  }

  void _onPlain(Uint8List plain) {
    if (plain.isEmpty) return;
    _rxLog('rx', 'RX 解密明文 ${plain.length}B', plain);
    _parse(plain);
  }

  /// Advance the handshake with buffered server data, then send our next flight.
  Future<void> tlsSendNext({int chunk = 0, double delay = 0}) async {
    if (tlsId == null) {
      emit('err', '尚未开始 TLS');
      return;
    }
    if (tlsPlain) {
      emit('err', '对端不是 TLS 服务，无法继续握手');
      return;
    }
    if (tlsFailed) {
      emit('err', 'TLS 已失败，请重新 ① 建连后重试');
      return;
    }
    if (tlsDone) {
      emit('info', 'TLS 握手已完成', force: true);
      return;
    }
    if (_tlsClosed) {
      // the peer (or we) closed the TCP connection during the handshake; the TLS session went with it
      tlsFailed = true;
      lastTlsError ??= '连接已关闭，TLS 握手未完成';
      emit('err', '连接已关闭，TLS 握手未完成，请重新 ① 建连');
      return;
    }
    final r = await Native.tlsStep(tlsId!, _tlsPending.takeBytes());
    if (r.error != null) {
      tlsFailed = true;
      lastTlsError ??= r.error; // keep the first (root) error
      emit('err', 'TLS 握手失败: ${r.error}');
    }
    if (r.out.isNotEmpty) {
      final name = r.error != null
          ? 'Alert'
          : (_tlsSentHello ? '握手消息' : 'ClientHello');
      _tlsSentHello = true;
      if (chunk > 0) {
        await sendChunked(
          r.out,
          chunk,
          delay,
          raw: true,
          label: 'TX TLS $name 分片',
        );
      } else {
        await send(r.out, label: 'TX TLS $name', raw: true);
      }
    } else if (!r.done && r.error == null) {
      emit('info', '暂无要发送的握手数据：服务器回包还没到齐，稍后再点 ③', force: true);
    }
    if (r.done) {
      tlsDone = true;
      emit('state', 'TLS 握手完成 ${r.protocol} ${r.cipher} ALPN=${r.alpn ?? '-'}');
      _onPlain(r.plain);
    }
  }

  // ---------------------------------------------------------------- closing
  void shutdownWrite() {
    try {
      sock?.shutdown(SocketDirection.send);
      emit('state', '已半关闭 (发送 FIN，仍可接收)');
    } catch (e) {
      emit('err', '半关闭失败: $e');
    }
  }

  void close() {
    if (_closing || state == 'closed') return;
    _closing = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
    for (final task in _pendingConnects.toList()) {
      task.cancel();
    }
    emit('state', sock == null ? '已取消等待中的连接' : '本地 close() (FIN)');
    _finish('本地关闭');
  }

  void reset() {
    if (sock == null) {
      close();
      return;
    }
    if (state == 'closed') return;
    _closing = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
    try {
      sock!.setRawOption(_lingerZero());
      emit('state', '本地 RST 关闭 (SO_LINGER=0)');
    } catch (e) {
      emit('err', '设置 SO_LINGER 失败，改为普通关闭: $e');
    }
    sock!.close();
    _finish('本地关闭');
  }

  /// Linux/Android TCP_USER_TIMEOUT: how long sent-but-unacknowledged data may stay unacked
  /// before the kernel aborts the connection. Raised so that the kernel keeps retransmitting
  /// (with growing intervals) instead of dropping the connection before our own timeout.
  void _applyUserTimeout(RawSocket s) {
    if (Platform.isWindows) return _applyMaxRt(s);
    if (!(Platform.isAndroid || Platform.isLinux)) return;
    final msVal = timeout <= 0
        ? 0x7fffffff
        : ((timeout + 60) * 1000).round().clamp(1, 0x7fffffff);
    try {
      final b = ByteData(4)..setUint32(0, msVal, Endian.host);
      s.setRawOption(
        RawSocketOption(
          6 /* IPPROTO_TCP */,
          18 /* TCP_USER_TIMEOUT */,
          b.buffer.asUint8List(),
        ),
      );
      emit(
        'info',
        timeout <= 0
            ? 'TCP_USER_TIMEOUT=不限：对方不确认数据时系统持续重传，不会自行断开'
            : 'TCP_USER_TIMEOUT=${(msVal / 1000).toStringAsFixed(0)}s：由本程序的回包超时先判定',
      );
    } catch (e) {
      emit('info', '设置 TCP_USER_TIMEOUT 失败: $e');
    }
  }

  /// Windows TCP_MAXRT: how many seconds TCP keeps retransmitting unacknowledged data before it gives up
  /// (the default gives up after about 21s). -1 = never give up, same purpose as TCP_USER_TIMEOUT above.
  void _applyMaxRt(RawSocket s) {
    final secs = timeout <= 0
        ? -1
        : (timeout + 60).round().clamp(1, 0x7fffffff);
    try {
      final b = ByteData(4)..setInt32(0, secs, Endian.host);
      s.setRawOption(
        RawSocketOption(
          6 /* IPPROTO_TCP */,
          5 /* TCP_MAXRT */,
          b.buffer.asUint8List(),
        ),
      );
      emit(
        'info',
        timeout <= 0
            ? 'TCP_MAXRT=不限：对方不确认数据时系统持续重传，不会自行断开'
            : 'TCP_MAXRT=${secs}s：由本程序的回包超时先判定',
      );
    } catch (e) {
      emit('info', '设置 TCP_MAXRT 失败: $e');
    }
  }

  static RawSocketOption _lingerZero() {
    if (Platform.isWindows) {
      return RawSocketOption(0xffff, 0x0080, Uint8List.fromList([1, 0, 0, 0]));
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return RawSocketOption(
        0xffff,
        0x0080,
        Uint8List.fromList([1, 0, 0, 0, 0, 0, 0, 0]),
      );
    }
    return RawSocketOption(
      1,
      13,
      Uint8List.fromList([1, 0, 0, 0, 0, 0, 0, 0]),
    ); // Linux/Android
  }
}
