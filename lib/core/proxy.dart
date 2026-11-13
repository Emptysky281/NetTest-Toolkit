// Proxy config and SOCKS5 / HTTP CONNECT handshakes.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'platform.dart';

class ProxyConfig {
  ProxyConfig({
    this.mode = 'direct',
    this.host = '127.0.0.1',
    this.port = 10808,
    this.user = '',
    this.password = '',
    this.remoteDns = true,
  });
  String mode; // direct | socks5 | http | system
  String host;
  int port;
  String user;
  String password;
  bool remoteDns;

  /// A running job must not change when the settings page is edited.
  ProxyConfig copy() => ProxyConfig(
    mode: mode,
    host: host,
    port: port,
    user: user,
    password: password,
    remoteDns: remoteDns,
  );

  Future<ProxyConfig> resolved() async {
    if (mode != 'system') return this;
    final sp = await Native.systemProxy();
    if (sp == null) return ProxyConfig(mode: 'direct');
    return ProxyConfig(mode: sp.$1, host: sp.$2, port: sp.$3);
  }

  String describe() =>
      mode == 'direct' ? '直连(可被 VPN/TUN 透明劫持)' : '$mode://$host:$port';
}

/// Reads exact byte counts from a socket during a proxy handshake.
abstract class HandshakeIO {
  Future<Uint8List> readExact(int n);
  Future<Uint8List> readUntil(List<int> delim, {int max = 65536});
  Future<void> write(List<int> data);
}

const _socksErr = {
  1: 'general failure',
  2: 'not allowed',
  3: 'network unreachable',
  4: 'host unreachable',
  5: 'connection refused',
  6: 'TTL expired',
  7: 'command not supported',
  8: 'address type not supported',
};

Future<void> socks5Handshake(
  HandshakeIO io,
  String host,
  int port,
  String user,
  String pass,
) async {
  final methods = user.isNotEmpty ? [0, 2] : [0];
  await io.write([5, methods.length, ...methods]);
  final r = await io.readExact(2);
  if (r[0] != 5 || r[1] == 0xFF) throw const SocketException('SOCKS5 无可用认证方式');
  if (r[1] == 2) {
    final u = utf8.encode(user), p = utf8.encode(pass);
    await io.write([1, u.length, ...u, p.length, ...p]);
    if ((await io.readExact(2))[1] != 0) {
      throw const SocketException('SOCKS5 认证失败');
    }
  }
  final ip = InternetAddress.tryParse(host);
  final List<int> addr;
  if (ip != null) {
    addr = [ip.type == InternetAddressType.IPv4 ? 1 : 4, ...ip.rawAddress];
  } else {
    final hb = utf8.encode(host);
    addr = [3, hb.length, ...hb];
  }
  await io.write([5, 1, 0, ...addr, port >> 8, port & 0xff]);
  final h = await io.readExact(4);
  if (h[1] != 0) {
    throw SocketException('SOCKS5 CONNECT 失败: ${_socksErr[h[1]] ?? h[1]}');
  }
  if (h[3] == 1) {
    await io.readExact(4);
  } else if (h[3] == 4) {
    await io.readExact(16);
  } else {
    await io.readExact((await io.readExact(1))[0]);
  }
  await io.readExact(2);
}

Future<void> httpConnectHandshake(
  HandshakeIO io,
  String host,
  int port,
  String user,
  String pass,
) async {
  final target = host.contains(':') ? '[$host]:$port' : '$host:$port';
  var req = 'CONNECT $target HTTP/1.1\r\nHost: $target\r\n';
  if (user.isNotEmpty) {
    req +=
        'Proxy-Authorization: Basic ${base64.encode(utf8.encode('$user:$pass'))}\r\n';
  }
  await io.write(latin1.encode('$req\r\n'));
  final head = latin1.decode(await io.readUntil(const [13, 10, 13, 10]));
  final status = head.split('\r\n').first;
  final parts = status.split(' ');
  if (parts.length < 2 || parts[1] != '200') {
    throw SocketException('HTTP CONNECT 失败: $status');
  }
}
