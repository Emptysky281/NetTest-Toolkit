// App state: settings, log buffer (batched UI updates), multi rows, current runner and step session.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../core/http.dart';
import '../core/instance.dart';
import '../core/platform.dart';
import '../core/proxy.dart';
import '../core/runner.dart';
import '../core/session.dart';
import '../core/util.dart';
import '../core/win_dialog.dart';

const logKeep = 5000;

/// Default and range for「载荷最多显示B」: bytes of each TX/RX payload kept and shown in the log.
const payloadKeepDefault = 4096, payloadKeepMin = 16, payloadKeepMax = 65536;
const httpMethods = ['GET', 'HEAD', 'POST', 'OPTIONS'];
const payloadHistoryMax = 20;

/// Former pre-filled URL; a saved copy of it is cleared once on load.
const oldDefaultUrl = 'http://64.83.22.144:1919/data/1.txt';

/// Former pre-filled TCP-step payload; a saved copy of it is cleared once on load.
const oldDefaultRaw =
    r'GET /data/2.txt HTTP/1.1\r\nHost: 64.83.22.144:1919\r\n\r\n';
const proxyModes = ['direct', 'socks5', 'http', 'system'];

// Typed reads from saved JSON: a missing or wrongly typed key keeps the default.
T _rd<T>(Map m, String k, T d) {
  final v = m[k];
  if (d is double && v is num) return v.toDouble() as T;
  if (d is int && v is num) return v.toInt() as T;
  return v is T ? v : d;
}

String _rdOf(Map m, String k, List<String> allowed, String d) {
  final v = m[k];
  return v is String && allowed.contains(v) ? v : d;
}

class Settings {
  /// Target URL saved by versions that had one shared URL on the 设置 page (null = none). Read once on load
  /// and copied into every page whose own URL is still empty.
  static String? legacyUrl(Map m) {
    final v = m['url'];
    if (v is! String || v.trim().isEmpty || v == oldDefaultUrl) return null;
    return v.trim();
  }

  /// reply wait: give up after this many seconds without any data; 0 = wait forever
  double timeout = 8;

  /// DNS / TCP handshake / proxy / TLS limit; 0 = no app limit (the OS gives up after its SYN retries)
  double connectTimeout = 8;
  bool nodelay = true;
  ProxyConfig proxy = ProxyConfig();
  bool bindOn = true;
  int bindLo = 40000, bindHi = 40999;
  bool saveOn = true;
  String saveDir = '';

  /// false = accept untrusted / expired / hostname-mismatched certificates (default).
  bool verifyCerts = false;
  (int, int)? get bindRange =>
      bindOn && 1024 <= bindLo && bindLo <= bindHi && bindHi <= 65535
      ? (bindLo, bindHi)
      : null;
  String? get savePath => saveOn && saveDir.isNotEmpty ? saveDir : null;

  Map<String, Object?> toJson() => {
    'timeout': timeout,
    'connectTimeout': connectTimeout,
    'nodelay': nodelay,
    'proxy': {
      'mode': proxy.mode,
      'host': proxy.host,
      'port': proxy.port,
      'user': proxy.user,
      'password': proxy.password,
      'remoteDns': proxy.remoteDns,
    },
    'bindOn': bindOn,
    'bindLo': bindLo,
    'bindHi': bindHi,
    'saveOn': saveOn,
    'saveDir': saveDir,
    'verifyCerts': verifyCerts,
  };

  void fromJson(Map m) {
    timeout = _rd(m, 'timeout', timeout);
    connectTimeout = _rd(m, 'connectTimeout', connectTimeout);
    nodelay = _rd(m, 'nodelay', nodelay);
    final p = m['proxy'];
    if (p is Map) {
      proxy.mode = _rdOf(p, 'mode', proxyModes, proxy.mode);
      proxy.host = _rd(p, 'host', proxy.host);
      proxy.port = _rd(p, 'port', proxy.port);
      proxy.user = _rd(p, 'user', proxy.user);
      proxy.password = _rd(p, 'password', proxy.password);
      proxy.remoteDns = _rd(p, 'remoteDns', proxy.remoteDns);
    }
    bindOn = _rd(m, 'bindOn', bindOn);
    bindLo = _rd(m, 'bindLo', bindLo);
    bindHi = _rd(m, 'bindHi', bindHi);
    saveOn = _rd(m, 'saveOn', saveOn);
    saveDir = _rd(m, 'saveDir', saveDir);
    verifyCerts = _rd(m, 'verifyCerts', verifyCerts);
  }
}

class HttpOpts {
  /// Target URL of this page (单连接 / 多连接 each have their own).
  String url = '';
  String method = 'GET';
  bool keepAlive = true;
  int requests = 1;
  double interval = 0, hold = 0;
  bool split = false;
  double splitDelay = 0.2;
  String headers = '';

  /// Custom request body; escapes like \r \n \xNN are decoded before sending.
  String payload = '';

  HttpJob job(Settings s) => HttpJob(
    url.trim(),
    method: method.trim().toUpperCase().isEmpty
        ? 'GET'
        : method.trim().toUpperCase(),
    headers: headers,
    keepAlive: keepAlive,
    requestsPerConn: requests < 1 ? 1 : requests,
    interval: interval,
    hold: hold,
    timeout: s.timeout,
    connectTimeout: s.connectTimeout,
    nodelay: s.nodelay,
    splitSend: split,
    splitDelay: splitDelay,
    body: unescape(payload),
    verifyCerts: s.verifyCerts,
  );

  Map<String, Object?> toJson() => {
    'url': url,
    'method': method,
    'keepAlive': keepAlive,
    'requests': requests,
    'interval': interval,
    'hold': hold,
    'split': split,
    'splitDelay': splitDelay,
    'headers': headers,
    'payload': payload,
  };

  void fromJson(Map m) {
    url = _rd(m, 'url', url);
    if (url == oldDefaultUrl) url = '';
    method = _rdOf(m, 'method', httpMethods, method);
    keepAlive = _rd(m, 'keepAlive', keepAlive);
    requests = _rd(m, 'requests', requests);
    interval = _rd(m, 'interval', interval);
    hold = _rd(m, 'hold', hold);
    split = _rd(m, 'split', split);
    splitDelay = _rd(m, 'splitDelay', splitDelay);
    headers = _rd(m, 'headers', headers);
    payload = _rd(m, 'payload', payload);
  }
}

/// Which page produced a log entry. The 日志 page shows every entry; each function page shows only its own.
enum LogSrc { single, multi, step }

class LogItem {
  LogItem(this.e, this.payload, [int? fullLen, this.src])
    : fullLen = fullLen ?? payload?.length ?? 0;
  final Ev e;

  /// null = not from a function page (only on the 日志 page).
  final LogSrc? src;

  /// The first [payloadMax] bytes only, so the log's memory stays bounded.
  final Uint8List? payload;

  /// Size of the whole payload, to show how much was cut off.
  final int fullLen;
}

class StepOpts {
  /// Target URL of the 分阶段 page.
  String url = '';
  String method = 'GET';
  bool keepAlive = true;
  String sni = '', alpn = 'http/1.1';

  /// null = follow the global setting; bool = an explicit override for this page.
  bool? verify;
  bool fragHello = false;
  int chunk = 5;
  double chunkDelay = 0.3;
  String raw = '';
  bool rawBypassTls = false;
  String headers = '';

  Map<String, Object?> toJson() => {
    'url': url,
    'method': method,
    'keepAlive': keepAlive,
    'sni': sni,
    'alpn': alpn,
    'verify': verify,
    'fragHello': fragHello,
    'chunk': chunk,
    'chunkDelay': chunkDelay,
    'raw': raw,
    'rawBypassTls': rawBypassTls,
    'headers': headers,
  };

  void fromJson(Map m) {
    url = _rd(m, 'url', url);
    if (url == oldDefaultUrl) url = '';
    method = _rdOf(m, 'method', httpMethods, method);
    keepAlive = _rd(m, 'keepAlive', keepAlive);
    sni = _rd(m, 'sni', sni);
    alpn = _rd(m, 'alpn', alpn);
    verify = m['verify'] is bool ? m['verify'] as bool : null;
    fragHello = _rd(m, 'fragHello', fragHello);
    chunk = _rd(m, 'chunk', chunk);
    chunkDelay = _rd(m, 'chunkDelay', chunkDelay);
    raw = _rd(m, 'raw', raw);
    if (raw == oldDefaultRaw) raw = ''; // drop the old built-in example
    rawBypassTls = _rd(m, 'rawBypassTls', rawBypassTls);
    headers = _rd(m, 'headers', headers);
  }
}

class AppState {
  /// [settingsDir] is a test seam: it pins settings.json to that directory and skips the
  /// platform calls that only make sense on a real device.
  AppState({
    String? settingsDir,
    this.instanceLauncher,
    DesktopInstance? desktopInstance,
  }) : desktopInstance = desktopInstance ?? DesktopInstance.current {
    if (settingsDir != null) {
      usePrefsFile(settingsDir);
      settings.saveDir = settingsDir;
      _historyReady = _loadHistory(settingsDir);
    } else {
      _historyReady = _loadHistory();
      Native.defaultSaveDir().then(
        (d) {
          if (_disposed) return;
          if (settings.saveDir.isEmpty) settings.saveDir = d;
          _notifyStatus();
        },
        onError: (Object e, StackTrace st) {
          note('无法读取默认保存目录: $e');
        },
      );
    }
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _flush();
      if (++_ticks % 10 == 0) savePrefs(); // autosave once a second, only writes when something changed
    });
  }

  final NamedInstanceLauncher? instanceLauncher;
  final DesktopInstance desktopInstance;
  bool launchingInstance = false;
  int _nextInstance = 2;

  bool get supportsNamedInstances => Platform.isWindows;
  String get suggestedInstanceName {
    final name = desktopInstance.isolated
        ? desktopInstance.processName.substring(
            0,
            desktopInstance.processName.length - 4,
          )
        : 'nettest';
    final stem = name.length > 48 ? name.substring(0, 48) : name;
    return '${stem}_$_nextInstance';
  }

  final settings = Settings();
  final single = HttpOpts();
  final multi = HttpOpts();
  final step = StepOpts();
  int mCount = 10, mConc = 10;
  double mStagger = 0;
  bool mVerbose = false;

  /// Multi mode: send the request in plain text right after the TCP handshake (no TLS, even for https).
  bool mNoTls = false;

  /// Same option for the single-connection page.
  bool sNoTls = false;

  /// Multi mode: true = every connection uses the target URL; false = per-connection URLs in [mUrls].
  bool mSameUrl = true;

  /// Per-connection URLs (index 0 = connection #1). Blank = use the target URL. Kept even beyond
  /// [mCount] so lowering and raising the count does not lose entries.
  final List<String> mUrls = [];

  String mUrlAt(int i) => i < mUrls.length ? mUrls[i] : '';

  void setMUrl(int i, String v) {
    while (mUrls.length <= i) {
      mUrls.add('');
    }
    mUrls[i] = v.trim();
  }

  /// URL actually used by each of the [mCount] connections (blank per-connection entries fall back to the target).
  List<String> effectiveMultiUrls() => [
    for (var i = 0; i < mCount; i++)
      mSameUrl || mUrlAt(i).isEmpty ? multi.url.trim() : mUrlAt(i),
  ];

  /// Loads the last-used settings before the first frame (form fields read their value only once),
  /// and saves them again whenever the app leaves the foreground.
  static Future<AppState> create() async {
    final st = AppState();
    await st.loadPrefs();
    await st._historyReady;
    st._life = AppLifecycleListener(
      onStateChange: (s) {
        if (s != AppLifecycleState.resumed) st.savePrefs();
      },
      // Windows: closing the window ends the process without any lifecycle change, so save here
      // (the window close goes through this exit request).
      onExitRequested: () async {
        st.savePrefs();
        await st.flushHistory();
        return AppExitResponse.exit;
      },
    );
    return st;
  }

  int _ticks = 0;
  AppLifecycleListener? _life;
  File? _prefsFile;

  /// Set by [usePrefsFile] in tests, before the asynchronous default path is resolved.
  String? _prefsPathOverride;
  String? _savedPrefs;

  /// Everything the user can set on the pages, persisted as settings.json in the app documents dir.
  Map<String, Object?> prefs() => {
    'version': 2,
    'settings': settings.toJson(),
    'single': single.toJson(),
    'multi': multi.toJson(),
    'step': step.toJson(),
    'mCount': mCount,
    'mConc': mConc,
    'mStagger': mStagger,
    'mVerbose': mVerbose,
    'mNoTls': mNoTls,
    'sNoTls': sNoTls,
    'mSameUrl': mSameUrl,
    'mUrls': _trimmedUrls(),
    'showHex': showHex,
    'showPayload': showPayload,
    'autoscroll': autoscroll,
    'payloadMax': payloadMax,
    'payloadHistory': payloadHistory,
  };

  void applyPrefs(Map m) {
    Map sub(String k) => m[k] is Map ? m[k] as Map : const {};
    settings.fromJson(sub('settings'));
    final legacy = Settings.legacyUrl(sub('settings'));
    single.fromJson(sub('single'));
    multi.fromJson(sub('multi'));
    step.fromJson(sub('step'));
    // Old versions persisted an implicit false even when no override was chosen.
    if (_rd(m, 'version', 1) < 2 && step.verify == false) step.verify = null;
    if (legacy != null) {
      for (final o in [single, multi]) {
        if (o.url.isEmpty) o.url = legacy;
      }
      if (step.url.isEmpty) step.url = legacy;
    }
    mCount = _rd(m, 'mCount', mCount);
    mConc = _rd(m, 'mConc', mConc);
    mStagger = _rd(m, 'mStagger', mStagger);
    mVerbose = _rd(m, 'mVerbose', mVerbose);
    mNoTls = _rd(m, 'mNoTls', mNoTls);
    sNoTls = _rd(m, 'sNoTls', sNoTls);
    mSameUrl = _rd(m, 'mSameUrl', mSameUrl);
    final mu = m['mUrls'];
    if (mu is List) {
      mUrls
        ..clear()
        ..addAll(mu.take(5000).map((x) => x is String ? x.trim() : ''));
    }
    showHex = _rd(m, 'showHex', showHex);
    showPayload = _rd(m, 'showPayload', showPayload);
    autoscroll = _rd(m, 'autoscroll', autoscroll);
    payloadMax = _rd(
      m,
      'payloadMax',
      payloadMax,
    ).clamp(payloadKeepMin, payloadKeepMax);
    final h = m['payloadHistory'];
    if (h is List) {
      payloadHistory
        ..clear()
        ..addAll(
          h
              .whereType<String>()
              .where((x) => x.trim().isNotEmpty)
              .take(payloadHistoryMax),
        );
    }
  }

  /// [mUrls] without trailing blanks, so the saved file stays small.
  List<String> _trimmedUrls() {
    var n = mUrls.length;
    while (n > 0 && mUrls[n - 1].isEmpty) {
      n--;
    }
    return mUrls.sublist(0, n);
  }

  /// Custom payloads used on any page (newest first), shared by single, multi and step; saved in settings.json.
  final List<String> payloadHistory = [];

  void rememberPayload(String text) {
    if (text.trim().isEmpty) return;
    payloadHistory
      ..remove(text)
      ..insert(0, text);
    if (payloadHistory.length > payloadHistoryMax) {
      payloadHistory.removeRange(payloadHistoryMax, payloadHistory.length);
    }
    _notifyStatus();
  }

  void clearPayloadHistory() {
    payloadHistory.clear();
    _notifyStatus();
  }

  Future<void> loadPrefs() async {
    try {
      final base = _prefsPathOverride ?? await Native.dataDir();
      _prefsFile = File('$base${Platform.pathSeparator}settings.json');
      if (_prefsFile!.existsSync()) {
        final v = jsonDecode(await _prefsFile!.readAsString());
        if (v is Map) applyPrefs(v);
      }
    } catch (_) {} // unreadable or corrupt file: start with defaults
    _savedPrefs = jsonEncode(prefs());
    _notifyStatus();
  }

  /// Redirects settings.json to [dir] so a test can exercise the real file without platform channels.
  @visibleForTesting
  void usePrefsFile(String dir) {
    _prefsPathOverride = dir;
    _prefsFile = File('$dir${Platform.pathSeparator}settings.json');
  }

  /// Writes settings.json if anything changed since the last write (temp file + rename, so a kill mid-write
  /// never leaves a truncated file).
  void savePrefs() {
    final f = _prefsFile;
    if (f == null) return;
    final txt = jsonEncode(prefs());
    if (txt == _savedPrefs) return;
    try {
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(txt, flush: true);
      tmp.renameSync(f.path);
      _savedPrefs = txt;
    } catch (_) {}
  }

  /// Recently used URLs; serialize writes so independently running pages cannot
  /// race file truncation or resurrect entries after 清空.
  final List<String> history = [];
  File? _historyFile;
  late final Future<void> _historyReady;
  Future<void> _historyWrites = Future<void>.value();

  Future<void> _loadHistory([String? directory]) async {
    try {
      final base = directory ?? await Native.dataDir();
      _historyFile = File('$base${Platform.pathSeparator}url_history.json');
      if (_historyFile!.existsSync()) {
        final v = jsonDecode(await _historyFile!.readAsString());
        if (v is List) history.addAll(v.whereType<String>().take(20));
      }
    } catch (_) {}
    _notifyStatus();
  }

  Future<void> _persistHistory() {
    final file = _historyFile;
    if (file == null) return Future<void>.value();
    final text = jsonEncode(history);
    _historyWrites = _historyWrites
        .then((_) async {
          await file.parent.create(recursive: true);
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsString(text, flush: true);
          await tmp.rename(file.path);
        })
        .catchError((Object e, StackTrace st) {
          note('URL 历史保存失败: $e');
        });
    return _historyWrites;
  }

  Future<void> rememberUrl(String url) => rememberUrls([url]);

  Future<void> rememberUrls(Iterable<String> urls) async {
    final entries = urls
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty)
        .toList();
    if (entries.isEmpty) return;
    await _historyReady;
    if (_disposed) return;
    for (final url in entries) {
      history.remove(url);
      history.insert(0, url);
    }
    if (history.length > 20) history.removeRange(20, history.length);
    _notifyStatus();
    await _persistHistory();
  }

  Future<void> flushHistory() async {
    await _historyReady;
    await _historyWrites;
  }

  Future<void> clearHistory() async {
    await _historyReady;
    if (_disposed) return;
    history.clear();
    _notifyStatus();
    // Keep the file object alive: later runs must still persist new URLs.
    await _persistHistory();
  }

  final logs = <LogItem>[];
  final logVersion = ValueNotifier(0);
  final rowsVersion = ValueNotifier(0);
  final status = ValueNotifier(0); // running state, summary, step state
  final rows = <int, RowData>{};
  bool showHex = false, showPayload = true, autoscroll = true;
  int payloadMax = payloadKeepDefault;
  int totalLogs = 0;

  /// 单连接 and 多连接 run independently: each page has its own runner, busy state and 停止.
  MultiRunner? singleRunner, multiRunner;

  /// Connection URL of the current 分阶段 session (steps ②–⑥ use it, not whatever the box says now).
  String stepUrl = '';
  TcpSession? stepSess;
  Map<String, Object?>? lastSummary;
  String? lastNote;

  final List<LogItem> _pending = [];
  bool _disposed = false;
  bool _singleStarting = false, _multiStarting = false;
  bool _stepStarting = false, _stepOperating = false;
  int _singleEpoch = 0, _multiEpoch = 0, _stepEpoch = 0;
  late final Timer _timer;
  final messenger = GlobalKey<ScaffoldMessengerState>();

  bool get singleBusy => _singleStarting || (singleRunner?.running ?? false);
  bool get multiBusy => _multiStarting || (multiRunner?.running ?? false);
  bool get stepBusy => _stepStarting || _stepOperating;
  bool get stepVerify => step.verify ?? settings.verifyCerts;

  /// Anything running (app-bar spinner).
  bool get busy => singleBusy || multiBusy || stepBusy;

  void _notifyStatus() {
    if (!_disposed) status.value++;
  }

  void _enqueue(Ev e, LogSrc? src) {
    if (_disposed) return;
    final data = e.data;
    if (data is Uint8List) {
      final keep = payloadMax.clamp(payloadKeepMin, payloadKeepMax);
      final payload = e.kind == 'tx' || e.kind == 'rx'
          ? Uint8List.fromList(
              data.length > keep ? Uint8List.sublistView(data, 0, keep) : data,
            )
          : null;
      _pending.add(LogItem(Ev.metadata(e), payload, data.length, src));
    } else {
      _pending.add(LogItem(e, null, null, src));
    }
  }

  void sink(Ev e) => _enqueue(e, null);
  EventSink sinkFor(LogSrc src) =>
      (e) => _enqueue(e, src);
  void note(String msg, [LogSrc? src]) => _enqueue(Ev(0, 'info', msg), src);

  /// Entries of one function page (same objects as in [logs], capped separately so a busy page
  /// cannot push another page's history out).
  final Map<LogSrc, List<LogItem>> pageLogs = {
    for (final s in LogSrc.values) s: <LogItem>[],
  };

  List<LogItem> logsFor(LogSrc? src) => src == null ? logs : pageLogs[src]!;

  void toast(String msg) => messenger.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );

  void _flush() {
    if (_pending.isEmpty) return;
    final batch = List<LogItem>.of(_pending);
    _pending.clear();
    var logged = false, rowsChanged = false, statusChanged = false;
    for (final item in batch) {
      final e = item.e, src = item.src;
      if (e.kind == 'row') {
        if (src != LogSrc.multi) continue; // only the 多连接 table shows rows
        final r = e.data as RowData;
        rows[r.idx] = r;
        rowsChanged = true;
        continue;
      }
      if (e.kind == 'done' && src == LogSrc.multi) {
        lastSummary = e.data as Map<String, Object?>;
        statusChanged = true;
      }
      if (e.kind == 'state' || e.kind == 'close') statusChanged = true;
      logs.add(item);
      if (src != null) pageLogs[src]!.add(item);
      totalLogs++;
      logged = true;
    }
    if (logs.length > logKeep) logs.removeRange(0, logs.length - logKeep);
    for (final l in pageLogs.values) {
      if (l.length > logKeep) l.removeRange(0, l.length - logKeep);
    }
    if (logged) logVersion.value++;
    if (rowsChanged) rowsVersion.value++;
    if (statusChanged) status.value++;
  }

  /// Start a genuinely differently named executable, not a renamed window.
  Future<InstanceLaunchResult> launchNamedInstance(
    String name, {
    bool copySettings = true,
  }) async {
    if (_disposed) throw StateError('当前窗口已关闭');
    if (!supportsNamedInstances) {
      throw UnsupportedError('自定义进程名多开目前仅支持 Windows');
    }
    if (launchingInstance) throw StateError('正在准备新实例，请稍候');
    final filename = instanceExecutableName(name);
    final snapshot = copySettings ? prefs() : null;
    final historySnapshot = copySettings
        ? List<String>.of(history)
        : <String>[];
    launchingInstance = true;
    _notifyStatus();
    try {
      final launcher =
          instanceLauncher ??
          NamedInstanceLauncher(
            storageRoot: Directory(
              '${await Native.applicationDataDir()}${Platform.pathSeparator}instances',
            ),
          );
      final result = await launcher.launch(
        filename,
        preferences: snapshot,
        urlHistory: historySnapshot,
      );
      _nextInstance++;
      note(
        '已启动多开进程 ${result.processName}（PID ${result.processId}）\n'
        '独立配置：${result.profileDirectory}\n程序：${result.executablePath}',
      );
      toast('已启动 ${result.processName}（PID ${result.processId}）');
      return result;
    } catch (e) {
      _enqueue(Ev(0, 'err', '多开启动失败: $e'), null);
      rethrow;
    } finally {
      launchingInstance = false;
      _notifyStatus();
    }
  }

  // ---------------------------------------------------------------- actions
  /// True (after telling the user) when no target URL is filled in.
  /// True (after telling the user) when [url] is empty.
  bool _noUrl(String url) {
    if (url.trim().isNotEmpty) return false;
    toast('请先在本页填写目标 URL');
    return true;
  }

  bool _checkBusy(bool running) {
    if (running) {
      toast('本页已有测试在运行，请先停止');
      return true;
    }
    return false;
  }

  bool _validUrl(String url, LogSrc src) {
    try {
      parseUrl(url);
      return true;
    } catch (e) {
      toast('目标地址无效: $e');
      _enqueue(Ev(0, 'err', '目标地址无效: $e'), src);
      return false;
    }
  }

  Future<void> runSingle({bool connectOnly = false}) async {
    if (_disposed || _noUrl(single.url) || _checkBusy(singleBusy)) return;
    final epoch = ++_singleEpoch;
    _singleStarting = true;
    _notifyStatus();
    try {
      final job = single.job(settings);
      if (!_validUrl(job.url, LogSrc.single)) return;
      final proxy = settings.proxy.copy();
      final bindRange = settings.bindRange, savePath = settings.savePath;
      final noTls = connectOnly || sNoTls;
      final payload = single.payload;
      if (connectOnly) {
        job.requestsPerConn = 0;
        if (job.hold <= 0) job.hold = 30;
      }
      // History IO is independent of the test; a slow disk must not delay SYN.
      unawaited(rememberUrl(job.url));
      final outbound = await proxy.resolved();
      if (_disposed || epoch != _singleEpoch) return;
      if (connectOnly) {
        note(
          '仅建立 TCP 连接并保持 ${job.hold}s（不做 TLS 握手、不发送 HTTP 数据）',
          LogSrc.single,
        );
      } else {
        rememberPayload(payload);
        note(
          '单连接测试 ${job.method} ${job.url} via ${outbound.describe()}',
          LogSrc.single,
        );
        if (noTls) {
          note('已勾选「不做 TLS 握手」：https 连接在 TCP 握手后直接发送明文 HTTP 请求', LogSrc.single);
        }
      }
      _start(
        LogSrc.single,
        MultiRunner(
          job,
          outbound,
          sinkFor(LogSrc.single),
          count: 1,
          concurrency: 1,
          verbose: true,
          bindRange: bindRange,
          saveDir: savePath,
          noTls: noTls,
        ),
      );
    } catch (e) {
      if (epoch == _singleEpoch && !_disposed) {
        _enqueue(Ev(0, 'err', '启动单连接失败: $e'), LogSrc.single);
        toast('启动单连接失败: $e');
      }
    } finally {
      if (epoch == _singleEpoch) _singleStarting = false;
      _notifyStatus();
    }
  }

  Future<void> runMulti(BuildContext context) async {
    if (_disposed || _checkBusy(multiBusy)) return;
    final epoch = ++_multiEpoch;
    _multiStarting = true;
    _notifyStatus();
    try {
      final urls = effectiveMultiUrls();
      final missing = urls.indexWhere((u) => u.isEmpty);
      if (missing >= 0) {
        toast(
          mSameUrl
              ? '请先在本页填写目标 URL'
              : '连接 #${missing + 1} 没有 URL：请填写，或在本页填写目标 URL',
        );
        return;
      }
      final distinct = urls.toSet().toList();
      if (distinct.any((url) => !_validUrl(url, LogSrc.multi))) return;
      final job = multi.job(settings);
      final proxy = settings.proxy.copy();
      final br = settings.bindRange, savePath = settings.savePath;
      final count = mCount, concurrency = mConc, stagger = mStagger;
      final verbose = mVerbose, noTls = mNoTls, payload = multi.payload;
      if (br != null && count > br.$2 - br.$1 + 1) {
        if (!context.mounted) return;
        final go = await confirm(
          context,
          '端口段可能不够',
          '本次需要 $count 个本地端口，端口段只有 ${br.$2 - br.$1 + 1} 个。关闭的端口约 1-2 分钟内处于 TIME_WAIT 不能复用，'
              '可能导致建连失败。建议扩大端口段或关闭「固定本地端口段」。仍要继续？',
        );
        if (!go || _disposed || epoch != _multiEpoch) return;
      }
      unawaited(rememberUrls(distinct.reversed));
      final outbound = await proxy.resolved();
      if (_disposed || epoch != _multiEpoch) return;
      rows.clear();
      rowsVersion.value++;
      lastSummary = null;
      rememberPayload(payload);
      note(
        '多连接测试 $count 个连接，并发 $concurrency，${job.method} '
        '${distinct.length == 1 ? distinct.first : '${distinct.length} 个不同 URL（每条连接见列表）'}',
        LogSrc.multi,
      );
      if (noTls) {
        note('已勾选「不做 TLS 握手」：https 连接在 TCP 握手后直接发送明文 HTTP 请求', LogSrc.multi);
      }
      _start(
        LogSrc.multi,
        MultiRunner(
          job,
          outbound,
          sinkFor(LogSrc.multi),
          count: count,
          concurrency: concurrency,
          stagger: stagger,
          verbose: verbose,
          bindRange: br,
          saveDir: savePath,
          urls: urls,
          noTls: noTls,
        ),
      );
    } catch (e) {
      if (epoch == _multiEpoch && !_disposed) {
        _enqueue(Ev(0, 'err', '启动多连接失败: $e'), LogSrc.multi);
        toast('启动多连接失败: $e');
      }
    } finally {
      if (epoch == _multiEpoch) _multiStarting = false;
      _notifyStatus();
    }
  }

  void _start(LogSrc src, MultiRunner r) {
    if (_disposed) {
      r.cancel();
      return;
    }
    if (src == LogSrc.multi) {
      multiRunner = r;
    } else {
      singleRunner = r;
    }
    r.start();
    _notifyStatus();
    r.done.then(
      (_) => _notifyStatus(),
      onError: (Object e, StackTrace st) {
        _enqueue(Ev(0, 'err', '测试异常终止: $e'), src);
        _notifyStatus();
      },
    );
  }

  /// Stop also invalidates a run that is still awaiting history/proxy/dialog IO.
  void stop(LogSrc src) {
    final running = src == LogSrc.multi ? multiBusy : singleBusy;
    if (!running) return;
    if (src == LogSrc.multi) {
      _multiEpoch++;
      _multiStarting = false;
      multiRunner?.cancel();
    } else {
      _singleEpoch++;
      _singleStarting = false;
      singleRunner?.cancel();
    }
    note('已请求停止', src);
    _notifyStatus();
  }

  // step mode
  TcpSession? _ready() {
    final s = stepSess;
    if (s == null || s.state != 'established') {
      toast('请先执行 ① TCP 握手');
      return null;
    }
    return s;
  }

  Future<void> stepConnect() async {
    if (_disposed || _noUrl(step.url) || _checkBusy(stepBusy)) return;
    final url = step.url.trim();
    if (!_validUrl(url, LogSrc.step)) return;
    final u = parseUrl(url);
    final epoch = ++_stepEpoch;
    _stepStarting = true;
    stepSess?.close();
    stepUrl = url;
    final s = TcpSession(
      u.host,
      u.port,
      settings.proxy,
      sinkFor(LogSrc.step),
      timeout: settings.timeout,
      connectTimeout: settings.connectTimeout,
      nodelay: settings.nodelay,
      bindRange: settings.bindRange,
      verifyCerts: settings.verifyCerts,
    )..setSave(settings.savePath);
    stepSess = s;
    _notifyStatus();
    try {
      unawaited(rememberUrl(url));
      if (_disposed || epoch != _stepEpoch) return;
      if (u.scheme == 'https') {
        note('HTTPS 目标：TCP 建立后请手动执行 ② ③ 完成 TLS 握手', LogSrc.step);
      }
      await s.connect();
    } catch (e) {
      if (epoch == _stepEpoch && !_disposed) {
        _enqueue(Ev(s.cid, 'err', '分阶段建连失败: $e'), LogSrc.step);
      }
    } finally {
      if (_disposed || epoch != _stepEpoch) {
        s.close();
      }
      if (epoch == _stepEpoch) _stepStarting = false;
      _notifyStatus();
    }
  }

  Future<void> _stepAction(
    Future<void> Function(TcpSession s, bool Function() current) action,
  ) async {
    if (_disposed || _checkBusy(stepBusy)) return;
    final s = _ready();
    if (s == null) return;
    final epoch = _stepEpoch;
    bool current() =>
        !_disposed &&
        epoch == _stepEpoch &&
        identical(s, stepSess) &&
        s.state == 'established';
    _stepOperating = true;
    _notifyStatus();
    try {
      await action(s, current);
    } catch (e) {
      if (current()) {
        _enqueue(Ev(s.cid, 'err', '分阶段操作失败: $e'), LogSrc.step);
        toast('分阶段操作失败: $e');
      }
    } finally {
      if (epoch == _stepEpoch) _stepOperating = false;
      _notifyStatus();
    }
  }

  Future<void> stepTlsHello(BuildContext context) => _stepAction((
    s,
    current,
  ) async {
    if (!Native.manualTlsSupported) {
      toast(Native.manualTlsUnavailable ?? '手动 TLS 分阶段不可用');
      return;
    }
    if (s.tlsId != null) {
      toast('本连接已发送过 ClientHello，请点 ③ 或重新 ①');
      return;
    }
    final u = parseUrl(stepUrl);
    if (u.scheme != 'https') {
      if (!context.mounted ||
          !await confirm(
            context,
            '确认',
            '当前 URL 是 ${u.scheme}://（端口 ${u.port}），对端很可能不是 TLS 服务，会直接回错误并断开。仍要发送 ClientHello？',
          )) {
        return;
      }
    }
    if (!current()) return;
    await s.tlsBegin(
      step.sni.trim().isEmpty ? u.host : step.sni.trim(),
      verify: stepVerify,
      alpn: step.alpn,
    );
    if (current()) {
      await s.tlsSendNext(
        chunk: step.fragHello ? step.chunk : 0,
        delay: step.chunkDelay,
      );
    }
  });

  Future<void> stepTlsNext() => _stepAction((s, current) async {
    if (s.tlsId == null) {
      toast('请先执行 ② 发 ClientHello');
      return;
    }
    await s.tlsSendNext(
      chunk: step.fragHello ? step.chunk : 0,
      delay: step.chunkDelay,
    );
  });

  ({String method, List<Uint8List> parts, String path}) _stepParts() {
    final u = parseUrl(stepUrl);
    final m = step.method.trim().isEmpty
        ? 'GET'
        : step.method.trim().toUpperCase();
    return (
      method: m,
      parts: buildHttpRequest(
        m,
        u.host,
        u.port,
        u.path,
        extraHeaders: step.headers,
        keepAlive: step.keepAlive,
        scheme: u.scheme,
      ),
      path: u.path,
    );
  }

  bool _canSendHttp(TcpSession s) {
    if (s.tlsId != null && !s.tlsDone) {
      toast('TLS 握手未完成，请先完成 ②③');
      return false;
    }
    return true;
  }

  Future<void> stepSend(int? idx) => _stepAction((s, current) async {
    if (!_canSendHttp(s)) return;
    final r = _stepParts();
    if (idx == null || idx == 0) s.expectResponse(r.method, r.path);
    if (idx == null) {
      await s.send(
        Uint8List.fromList([for (final p in r.parts) ...p]),
        label: 'TX 完整请求',
      );
    } else {
      await s.send(
        r.parts[idx],
        label: const ['TX 请求行', 'TX 请求头', 'TX 空行'][idx],
      );
    }
  });

  Future<void> stepChunked() => _stepAction((s, current) async {
    if (!_canSendHttp(s)) return;
    final r = _stepParts();
    s.expectResponse(r.method, r.path);
    await s.sendChunked(
      Uint8List.fromList([for (final p in r.parts) ...p]),
      step.chunk,
      step.chunkDelay,
      stopped: () => !current(),
    );
  });

  Future<void> stepRaw() => _stepAction((s, current) async {
    if (!step.rawBypassTls && !_canSendHttp(s)) return;
    rememberPayload(step.raw);
    final data = unescape(step.raw);
    final head = latin1.decode(data.take(200).toList(), allowInvalid: true);
    if (head.startsWith('GET /') ||
        head.startsWith('HEAD ') ||
        head.contains(' HTTP/1.')) {
      final first = head.split('\r\n').first.split(' ');
      s.expectResponse(
        head.startsWith('HEAD') ? 'HEAD' : 'GET',
        first.length > 1 ? first[1] : '/',
      );
    }
    await s.send(data, label: 'TX 自定义', raw: step.rawBypassTls);
  });

  void stepClose(String how) {
    final s = stepSess;
    if (s == null) return;
    _stepEpoch++;
    _stepStarting = _stepOperating = false;
    switch (how) {
      case 'half':
        s.shutdownWrite();
      case 'fin':
        s.close();
      case 'rst':
        s.reset();
    }
    _notifyStatus();
  }

  String stepStateText() {
    final s = stepSess;
    if (s == null) return '未连接';
    var st = '#${s.cid} ${s.state}';
    if (s.state == 'established' && s.tlsId != null) {
      st += ' / TLS ${s.tlsDone ? '已完成' : '握手中'}';
    }
    return st;
  }

  // ---------------------------------------------------------------- export
  Future<String> _outDir() async {
    final d = settings.saveDir.isNotEmpty
        ? settings.saveDir
        : await Native.defaultSaveDir();
    await Directory(d).create(recursive: true);
    return d;
  }

  String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  Future<void> exportCsv() async {
    if (rows.isEmpty) {
      toast('表格为空');
      return;
    }
    String q(String v) =>
        v.contains(RegExp(r'[",\n]')) ? '"${v.replaceAll('"', '""')}"' : v;
    final sb = StringBuffer('\uFEFF')
      ..writeln(RowData.csvHeader.map(q).join(','));
    for (final k in rows.keys.toList()..sort()) {
      sb.writeln(rows[k]!.toCsv().map(q).join(','));
    }
    if (lastSummary != null) {
      sb.writeln();
      sb.writeln(
        'URL,${q(multi.url)},出站,${q((await settings.proxy.resolved()).describe())}',
      );
      for (final l in (lastSummary!['text'] as String).split('\n')) {
        sb.writeln(q(l.trim()));
      }
    }
    final f = await _savePath('导出 CSV', 'multi_${_stamp()}.csv', 'csv', (
      'CSV',
      '*.csv',
    ));
    if (f == null) return;
    await f.writeAsString(sb.toString());
    note('已导出 CSV -> ${f.path}', LogSrc.multi);
    toast('已导出 ${f.path}');
  }

  Future<void> saveLog() async {
    final f = await _savePath('保存日志', 'nettest_${_stamp()}.log', 'log', (
      '日志',
      '*.log',
    ));
    if (f == null) return;
    await f.writeAsString(
      logs.map((l) => formatLine(l, hex: showHex, payload: true)).join('\n'),
    );
    toast('已保存 ${f.path}');
  }

  /// Windows: a "save as" dialog starting in the save folder with [name] filled in (null = cancelled).
  /// Android: [name] in the save folder directly, as before.
  Future<File?> _savePath(
    String title,
    String name,
    String ext,
    (String, String) filter,
  ) async {
    final dir = await _outDir();
    if (!Platform.isWindows) return File('$dir${Platform.pathSeparator}$name');
    try {
      final path = await windowsSaveDialog(
        title: title,
        windowTitle: desktopInstance.windowTitle,
        initialDir: dir,
        fileName: name,
        defaultExt: ext,
        filter: [filter, ('所有文件', '*.*')],
      );
      return path == null || path.isEmpty ? null : File(path);
    } catch (_) {
      return File(
        '$dir${Platform.pathSeparator}$name',
      ); // dialog unavailable: keep the old behaviour
    }
  }

  /// 清空 on the 日志 page: everything, including each page's view.
  void clearLog() {
    logs.clear();
    for (final l in pageLogs.values) {
      l.clear();
    }
    logVersion.value++;
  }

  static String time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';

  static String head(LogItem l) =>
      '${time(l.e.t)} [${l.e.cid > 0 ? '#${l.e.cid}' : '--'}] ${l.e.msg}';

  static String? payloadText(LogItem l, bool hex) {
    final p = l.payload;
    if (p == null || p.isEmpty) return null;
    final cut = l.fullLen > p.length
        ? '\n... (截断，剩余 ${l.fullLen - p.length}B)'
        : '';
    if (hex || isBinary(p)) {
      return '${!hex ? '(二进制数据，自动以 HEX 显示)\n' : ''}${hexDump(p)}$cut';
    }
    return '${textView(p)}$cut';
  }

  static String formatLine(
    LogItem l, {
    required bool hex,
    required bool payload,
  }) {
    final pt = payload ? payloadText(l, hex) : null;
    return pt == null
        ? head(l)
        : '${head(l)}\n${pt.split('\n').map((x) => '      $x').join('\n')}';
  }

  void dispose() {
    if (_disposed) return;
    savePrefs();
    _disposed = true;
    _singleEpoch++;
    _multiEpoch++;
    _stepEpoch++;
    singleRunner?.cancel();
    multiRunner?.cancel();
    stepSess?.close();
    _pending.clear();
    _life?.dispose();
    _timer.cancel();
  }
}

Future<bool> confirm(BuildContext context, String title, String msg) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('继续'),
          ),
        ],
      ),
    ) ??
    false;
