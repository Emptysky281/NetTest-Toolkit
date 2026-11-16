import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nettest/core/platform.dart';
import 'package:nettest/core/session.dart';
import 'package:nettest/ui/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('nt_prefs_test');
    file = File('${dir.path}${Platform.pathSeparator}settings.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('first run writes nothing, then changes autosave to settings.json', () async {
    final st = AppState(settingsDir: dir.path);
    await st.loadPrefs();
    expect(file.existsSync(), isFalse, reason: 'defaults alone are not worth a write');

    st.single.url = 'https://saved.example/y';
    st.mCount = 42;
    st.single.requests = 5;
    st.step.raw = r'X\r\n';
    st.autoscroll = false;
    st.savePrefs();
    expect(file.existsSync(), isTrue);

    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['single']['url'], 'https://saved.example/y');
    expect(saved['mCount'], 42);
    expect(saved['single']['requests'], 5);
    expect(saved['step']['raw'], r'X\r\n');
    expect(saved['autoscroll'], false);
    st.dispose();
  });

  test('a second run restores every saved value', () async {
    final a = AppState(settingsDir: dir.path);
    await a.loadPrefs();
    a.single.url = 'https://saved.example/y';
    a.settings
      ..timeout = 0
      ..verifyCerts = true
      ..saveOn = false;
    a.settings.proxy
      ..mode = 'socks5'
      ..host = '10.0.0.1'
      ..port = 1080;
    a.multi
      ..method = 'HEAD'
      ..requests = 3
      ..payload = r'-d a=1\r\n';
    a.single.payload = 'single-body';
    a.mCount = 42;
    a.mVerbose = true;
    a.mNoTls = true;
    a.sNoTls = true;
    a.step..sni = 'sni.test'..chunk = 9;
    a.showHex = true;
    a.savePrefs();
    a.dispose();

    final b = AppState(settingsDir: dir.path);
    await b.loadPrefs();
    expect(b.single.url, 'https://saved.example/y');
    expect(b.settings.timeout, 0);
    expect(b.settings.verifyCerts, isTrue);
    expect(b.settings.saveOn, isFalse);
    expect(b.settings.proxy.mode, 'socks5');
    expect(b.settings.proxy.host, '10.0.0.1');
    expect(b.settings.proxy.port, 1080);
    expect(b.multi.method, 'HEAD');
    expect(b.multi.requests, 3);
    expect(b.multi.payload, r'-d a=1\r\n');
    expect(b.single.payload, 'single-body');
    expect(b.mCount, 42);
    expect(b.mVerbose, isTrue);
    expect(b.mNoTls, isTrue);
    expect(b.sNoTls, isTrue);
    expect(b.step.sni, 'sni.test');
    expect(b.step.chunk, 9);
    expect(b.showHex, isTrue);
    b.dispose();
  });

  test('a corrupt file falls back to defaults and is replaced on the next save', () async {
    file.writeAsStringSync('{broken');
    final st = AppState(settingsDir: dir.path);
    await st.loadPrefs();
    expect(st.single.url, '');
    expect(st.mCount, 10);
    st.mCount = 11;
    st.savePrefs();
    expect((jsonDecode(file.readAsStringSync()) as Map)['mCount'], 11);
    st.dispose();
  });

  test('bad or missing values keep defaults', () {
    final d = Settings().toJson();
    expect((Settings()..fromJson({'url': 5, 'timeout': 'x', 'proxy': {'mode': 'bogus', 'port': '1'}})).toJson(), d);
    final h = HttpOpts()..fromJson({'method': 'DELETE', 'requests': 2.0});
    expect(h.method, 'GET', reason: 'a method that is not in the drop-down is rejected');
    expect(h.requests, 2, reason: 'a whole number read from JSON stays valid');
  });

  test('the periodic autosave writes without being asked', () async {
    final st = AppState(settingsDir: dir.path);
    await st.loadPrefs();
    st.single.url = 'https://autosaved.example/z';
    expect(file.existsSync(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(file.existsSync(), isTrue, reason: 'the 1 Hz autosave timer writes the change');
    expect((jsonDecode(file.readAsStringSync()) as Map)['single']['url'], 'https://autosaved.example/z');
    st.dispose();
  });

  test('page URLs start empty; a saved old default is cleared, other URLs are kept', () {
    expect([HttpOpts().url, StepOpts().url], ['', '']);
    expect((HttpOpts()..fromJson({'url': oldDefaultUrl})).url, '');
    expect((StepOpts()..fromJson({'url': oldDefaultUrl})).url, '');
    expect((HttpOpts()..fromJson({'url': 'http://my.host/x'})).url, 'http://my.host/x');
  });

  test('migration: the old shared URL fills every page that has none, once', () {
    final a = AppState(settingsDir: dir.path)
      ..applyPrefs({
        'settings': {'url': 'http://old.shared/x', 'timeout': 5},
        'step': {'url': 'http://step.own/y'},
      });
    expect([a.single.url, a.multi.url, a.step.url], ['http://old.shared/x', 'http://old.shared/x', 'http://step.own/y'],
        reason: 'a page that already has its own URL keeps it');
    expect(a.settings.timeout, 5);
    final saved = a.prefs();
    expect((saved['settings'] as Map).containsKey('url'), isFalse, reason: 'the shared URL is not written back');
    expect((saved['multi'] as Map)['url'], 'http://old.shared/x');
    a.dispose();
    final c = AppState(settingsDir: dir.path)..applyPrefs({'settings': {'url': oldDefaultUrl}});
    expect([c.single.url, c.multi.url, c.step.url], ['', '', ''], reason: 'the old built-in example is not migrated');
    c.dispose();
  });

  test('step payload starts empty; a saved old default is cleared', () {
    expect(StepOpts().raw, '');
    expect((StepOpts()..fromJson({'raw': oldDefaultRaw})).raw, '');
    expect((StepOpts()..fromJson({'raw': 'my own'})).raw, 'my own');
  });

  test('payload history: newest first, deduplicated, capped, blanks ignored, persisted', () async {
    final a = AppState(settingsDir: dir.path);
    await a.loadPrefs();
    for (var i = 0; i < 25; i++) {
      a.rememberPayload('p$i');
    }
    a.rememberPayload('p3');
    a.rememberPayload('   ');
    expect(a.payloadHistory.length, payloadHistoryMax);
    expect(a.payloadHistory.first, 'p3');
    expect(a.payloadHistory.where((x) => x == 'p3').length, 1);
    expect(a.payloadHistory.contains('   '), isFalse);
    final want = List<String>.of(a.payloadHistory);
    a.savePrefs();
    a.dispose();

    final b = AppState(settingsDir: dir.path);
    await b.loadPrefs();
    expect(b.payloadHistory, want);
    b.clearPayloadHistory();
    b.savePrefs();
    b.dispose();
    expect((jsonDecode(file.readAsStringSync()) as Map)['payloadHistory'], isEmpty);
  });

  test('per-connection URLs: fallback, validation input, persisted, trailing blanks trimmed', () async {
    final a = AppState(settingsDir: dir.path);
    await a.loadPrefs();
    expect(a.mSameUrl, isTrue, reason: 'default: every connection uses the target URL');
    expect(a.mNoTls, isFalse, reason: 'default: https connections do the TLS handshake');
    expect(a.sNoTls, isFalse);
    a.multi.url = 'http://target/t';
    a.mCount = 4;
    a.setMUrl(0, ' http://a/1 ');
    a.setMUrl(2, 'http://c/3');
    a.setMUrl(7, ''); // beyond the count, blank
    expect(a.effectiveMultiUrls(), List.filled(4, 'http://target/t'), reason: 'same-URL switch on');
    a.mSameUrl = false;
    expect(a.effectiveMultiUrls(), ['http://a/1', 'http://target/t', 'http://c/3', 'http://target/t']);
    a.multi.url = '';
    expect(a.effectiveMultiUrls()[1], '', reason: 'blank row + no target URL is caught before running');
    a.savePrefs();
    a.dispose();
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['mUrls'], ['http://a/1', '', 'http://c/3'], reason: 'trailing blanks are not stored');

    final b = AppState(settingsDir: dir.path);
    await b.loadPrefs();
    expect(b.mSameUrl, isFalse);
    expect([for (var i = 0; i < 4; i++) b.mUrlAt(i)], ['http://a/1', '', 'http://c/3', '']);
    b.dispose();
  });

  test('Windows system proxy string parsing (same rules as the old Python client)', () {
    expect(Native.parseWindowsProxy('127.0.0.1:10809'), ('http', '127.0.0.1', 10809));
    expect(Native.parseWindowsProxy('http=127.0.0.1:8888;https=127.0.0.1:8889'), ('http', '127.0.0.1', 8888));
    expect(Native.parseWindowsProxy('socks=127.0.0.1:10808'), ('socks5', '127.0.0.1', 10808));
    expect(Native.parseWindowsProxy('https=1.2.3.4:443;socks=5.6.7.8:1080'), ('socks5', '5.6.7.8', 1080));
    expect(Native.parseWindowsProxy('http=[::1]:8080'), ('http', '::1', 8080));
    expect(Native.parseWindowsProxy('proxyhost'), ('http', 'proxyhost', 8080));
    expect(Native.parseWindowsProxy('ftp=1.1.1.1:21'), isNull);
  });

  test('log payload limit: default, clamped on load, persisted', () async {
    final a = AppState(settingsDir: dir.path);
    await a.loadPrefs();
    expect(a.payloadMax, payloadKeepDefault);
    a.payloadMax = 512;
    a.savePrefs();
    a.dispose();
    final b = AppState(settingsDir: dir.path);
    await b.loadPrefs();
    expect(b.payloadMax, 512);
    b.dispose();
    final c = AppState(settingsDir: dir.path)..applyPrefs({'payloadMax': 1 << 30});
    expect(c.payloadMax, payloadKeepMax);
    c.applyPrefs({'payloadMax': 1});
    expect(c.payloadMax, payloadKeepMin);
    c.dispose();
  });

  test('log payload: kept up to the limit, the cut-off size is shown', () {
    final full = Uint8List.fromList(List.filled(100, 0x41));
    final kept = LogItem(Ev(1, 'rx', 'RX'), Uint8List.sublistView(full, 0, 40), full.length);
    final t = AppState.payloadText(kept, false)!;
    expect(t.contains('A' * 40), isTrue);
    expect(t.contains('截断，剩余 60B'), isTrue);
    final whole = LogItem(Ev(1, 'rx', 'RX'), full);
    expect(AppState.payloadText(whole, false)!.contains('截断'), isFalse);
  });

  test('log routing: each page sees only its own entries, the 日志 page sees all in order', () async {
    final st = AppState(settingsDir: dir.path);
    st.sinkFor(LogSrc.single)(Ev(1, 'state', 'single-1'));
    st.sinkFor(LogSrc.multi)(Ev(2, 'state', 'multi-1'));
    st.note('global note');
    st.sinkFor(LogSrc.step)(Ev(3, 'state', 'step-1'));
    st.note('single note', LogSrc.single);
    await Future<void>.delayed(const Duration(milliseconds: 250)); // the 100 ms flush timer
    List<String> msgs(List<LogItem> l) => [for (final x in l) x.e.msg];
    expect(msgs(st.logsFor(null)), ['single-1', 'multi-1', 'global note', 'step-1', 'single note']);
    expect(msgs(st.logsFor(LogSrc.single)), ['single-1', 'single note']);
    expect(msgs(st.logsFor(LogSrc.multi)), ['multi-1']);
    expect(msgs(st.logsFor(LogSrc.step)), ['step-1']);
    st.clearLog();
    expect([for (final s in [null, ...LogSrc.values]) st.logsFor(s).length], [0, 0, 0, 0],
        reason: '清空 on the 日志 page clears every view');
    st.dispose();
  });

  test('log routing: a busy page does not push another page\'s history out', () async {
    final st = AppState(settingsDir: dir.path);
    st.sinkFor(LogSrc.single)(Ev(1, 'state', 'keep me'));
    final multi = st.sinkFor(LogSrc.multi);
    for (var i = 0; i < logKeep + 500; i++) {
      multi(Ev(2, 'state', 'm$i'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(st.logsFor(LogSrc.single).single.e.msg, 'keep me');
    expect(st.logsFor(LogSrc.multi).length, logKeep);
    expect(st.logsFor(null).length, logKeep, reason: 'the full log keeps its own cap');
    st.dispose();
  });

  test('a half-typed number does not overwrite the last good value', () async {
    final a = AppState(settingsDir: dir.path);
    await a.loadPrefs();
    a.settings.connectTimeout = 3.5;
    a.savePrefs();
    a.dispose();

    final raw = jsonDecode(file.readAsStringSync()) as Map;
    raw['settings']['connectTimeout'] = 'not a number';
    file.writeAsStringSync(jsonEncode(raw));

    final b = AppState(settingsDir: dir.path);
    await b.loadPrefs();
    expect(b.settings.connectTimeout, 8, reason: 'wrong type keeps the default');
    b.savePrefs();
    b.dispose();
  });
}
