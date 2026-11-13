// Native bridge. Android: manual TLS via SSLEngine (MethodChannel). Windows: manual TLS via OpenSSL
// (dart:ffi, tls_openssl.dart) and the system proxy from the registry. Plus the default storage dir.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'instance.dart';
import 'tls_openssl.dart';

class TlsStep {
  TlsStep(Map m)
    : out = (m['out'] as Uint8List?) ?? Uint8List(0),
      plain = (m['plain'] as Uint8List?) ?? Uint8List(0),
      done = m['done'] == true,
      error = m['error'] as String?,
      protocol = m['protocol'] as String?,
      cipher = m['cipher'] as String?,
      alpn = m['alpn'] as String?,
      closed = m['closed'] == true;
  final Uint8List out, plain;
  final bool done, closed;
  final String? error, protocol, cipher, alpn;
}

class Native {
  static const _ch = MethodChannel('nettest/native');
  static bool get _win => Platform.isWindows;

  /// Manual step-by-step TLS: Android (SSLEngine) and Windows (OpenSSL, when its DLLs are present).
  static bool get manualTlsSupported =>
      Platform.isAndroid || (_win && OpenSslTls.unavailable == null);

  /// Why manual TLS is unavailable on this platform (null when it works).
  static String? get manualTlsUnavailable => Platform.isAndroid
      ? null
      : _win
      ? OpenSslTls.unavailable
      : '手动 TLS 分阶段仅支持 Android 和 Windows';

  static Future<int> tlsBegin(
    String host,
    int port,
    String sni,
    bool verify,
    List<String> alpn,
  ) async => _win
      ? OpenSslTls.begin(host, port, sni, verify, alpn)
      : (await _ch.invokeMethod<int>('tlsBegin', {
          'host': host,
          'port': port,
          'sni': sni,
          'verify': verify,
          'alpn': alpn,
        }))!;

  /// Feed buffered server bytes (may be empty) and advance the handshake; returns bytes to send.
  static Future<TlsStep> tlsStep(int id, Uint8List incoming) async => TlsStep(
    _win
        ? OpenSslTls.step(id, incoming)
        : (await _ch.invokeMethod<Map>('tlsStep', {
            'id': id,
            'data': incoming,
          }))!,
  );

  static Future<TlsStep> tlsDecrypt(int id, Uint8List data) async => TlsStep(
    _win
        ? OpenSslTls.decrypt(id, data)
        : (await _ch.invokeMethod<Map>('tlsDecrypt', {
            'id': id,
            'data': data,
          }))!,
  );

  static Future<TlsStep> tlsEncrypt(int id, Uint8List data) async => TlsStep(
    _win
        ? OpenSslTls.encrypt(id, data)
        : (await _ch.invokeMethod<Map>('tlsEncrypt', {
            'id': id,
            'data': data,
          }))!,
  );

  static Future<void> tlsClose(int id) async {
    try {
      if (_win) {
        OpenSslTls.close(id);
      } else {
        await _ch.invokeMethod('tlsClose', {'id': id});
      }
    } catch (_) {}
  }

  /// (mode, host, port) of the system proxy, mode = 'http' | 'socks5'; null = none (direct).
  static Future<(String, String, int)?> systemProxy() async {
    if (_win) return windowsProxy();
    if (!Platform.isAndroid) return null;
    try {
      final m = await _ch.invokeMethod<Map>('systemProxy');
      if (m == null || (m['host'] as String?)?.isEmpty != false) return null;
      return ('http', m['host'] as String, m['port'] as int);
    } catch (_) {
      return null;
    }
  }

  /// Windows Internet Settings (HKCU), same rules as the old Python client: an http entry wins,
  /// then socks; "host:port" alone means http for every scheme.
  static Future<(String, String, int)?> windowsProxy() async {
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    String? val(String out, String name) {
      final m = RegExp(
        '^\\s*$name\\s+REG_\\w+\\s+(.*)\$',
        multiLine: true,
      ).firstMatch(out);
      return m?.group(1)?.trim();
    }

    try {
      final r = await Process.run('reg', ['query', key]);
      if (r.exitCode != 0) return null;
      final out = r.stdout as String;
      final enabled = val(out, 'ProxyEnable');
      final server = val(out, 'ProxyServer') ?? '';
      if (enabled == null ||
          int.tryParse(enabled.replaceFirst('0x', ''), radix: 16) == 0 ||
          server.isEmpty) {
        return null;
      }
      return parseWindowsProxy(server);
    } catch (_) {
      return null;
    }
  }

  static (String, String, int)? parseWindowsProxy(String server) {
    final entries = <String, String>{};
    if (server.contains('=')) {
      for (final part in server.split(';')) {
        final i = part.indexOf('=');
        if (i > 0) {
          entries[part.substring(0, i).trim().toLowerCase()] = part
              .substring(i + 1)
              .trim();
        }
      }
    } else {
      entries['http'] = server.trim();
    }
    (String, int) hp(String s, int def) {
      s = s.trim();
      if (s.startsWith('[')) {
        final e = s.indexOf(']');
        final rest = s.substring(e + 1);
        return (
          s.substring(1, e),
          rest.startsWith(':') ? int.tryParse(rest.substring(1)) ?? def : def,
        );
      }
      final c = ':'.allMatches(s).length;
      if (c == 1) {
        final i = s.indexOf(':');
        return (s.substring(0, i), int.tryParse(s.substring(i + 1)) ?? def);
      }
      return (s, def);
    }

    if (entries['http'] case final h?) {
      final (host, port) = hp(h, 8080);
      return ('http', host, port);
    }
    if (entries['socks'] case final s?) {
      final (host, port) = hp(s, 1080);
      return ('socks5', host, port);
    }
    return null;
  }

  /// The base application directory is shared only as a container. Each named
  /// process uses its own sibling profile and never writes the main settings.
  static Future<String> applicationDataDir() async =>
      (_win
              ? await getApplicationSupportDirectory()
              : await getApplicationDocumentsDirectory())
          .path;

  static Future<String> dataDir() async {
    final profile = _win ? DesktopInstance.current.profileDirectory : null;
    if (profile == null) return applicationDataDir();
    await Directory(profile).create(recursive: true);
    return profile;
  }

  static Future<String> defaultSaveDir() async {
    final profile = _win ? DesktopInstance.current.profileDirectory : null;
    if (profile != null) return '$profile${Platform.pathSeparator}downloads';
    Directory? base;
    if (Platform.isAndroid) base = await getExternalStorageDirectory();
    if (_win) {
      final docs = await getApplicationDocumentsDirectory(); // the user's Documents folder
      return '${docs.path}${Platform.pathSeparator}NetTest${Platform.pathSeparator}downloads';
    }
    base ??= await getApplicationDocumentsDirectory();
    return '${base.path}${Platform.pathSeparator}downloads';
  }
}
