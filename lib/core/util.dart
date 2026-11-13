// Small helpers shared by the core (formatting, byte search, escapes).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

String ms(double secs) => '${(secs * 1000).toStringAsFixed(1)}ms';

String fmtSize(num n) {
  const units = ['B', 'KB', 'MB', 'GB'];
  double v = n.toDouble();
  for (var i = 0; i < units.length; i++) {
    if (v < 1024 || i == units.length - 1) {
      return i == 0
          ? '${v.toStringAsFixed(0)}B'
          : '${v.toStringAsFixed(2)}${units[i]}';
    }
    v /= 1024;
  }
  return '$n';
}

String fmtSpeed(num bytes, double secs) =>
    secs > 0 ? '${fmtSize(bytes / secs)}/s' : '-';

double? percentile(List<double> vals, double p) {
  if (vals.isEmpty) return null;
  final v = [...vals]..sort();
  final k = (v.length - 1) * p / 100;
  final lo = k.floor();
  final hi = (lo + 1).clamp(0, v.length - 1);
  return v[lo] + (v[hi] - v[lo]) * (k - lo);
}

/// Monotonic seconds.
final Stopwatch _clock = Stopwatch()..start();
double now() => _clock.elapsedMicroseconds / 1e6;

int indexOf(Uint8List hay, List<int> needle, [int start = 0, int? end]) {
  final e = (end ?? hay.length) - needle.length;
  outer:
  for (var i = start; i <= e; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

const crlf = [13, 10];
const crlfcrlf = [13, 10, 13, 10];

/// Turn \r \n \t \0 \\ \xNN escapes into bytes; everything else UTF-8.
Uint8List unescape(String s) {
  final out = BytesBuilder();
  var i = 0;
  const simple = {'r': 13, 'n': 10, 't': 9, '0': 0, '\\': 92};
  while (i < s.length) {
    final c = s[i];
    if (c == '\\' && i + 1 < s.length) {
      final n = s[i + 1];
      if (simple.containsKey(n)) {
        out.addByte(simple[n]!);
        i += 2;
        continue;
      }
      if (n == 'x' &&
          i + 4 <= s.length &&
          RegExp(r'^[0-9a-fA-F]{2}$').hasMatch(s.substring(i + 2, i + 4))) {
        out.addByte(int.parse(s.substring(i + 2, i + 4), radix: 16));
        i += 4;
        continue;
      }
    }
    // copy one full code point (surrogate pair aware)
    final cu = s.codeUnitAt(i);
    final len = (cu >= 0xD800 && cu < 0xDC00 && i + 1 < s.length) ? 2 : 1;
    out.add(utf8.encode(s.substring(i, i + len)));
    i += len;
  }
  return out.toBytes();
}

({String scheme, String host, int port, String path}) parseUrl(String url) {
  url = url.trim();
  if (url.isEmpty) throw const FormatException('目标 URL 不能为空');
  if (!url.contains('://')) url = 'http://$url';
  final u = Uri.parse(url);
  final scheme = u.scheme.isEmpty ? 'http' : u.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    throw FormatException('仅支持 http:// 或 https:// URL', url);
  }
  if (u.host.isEmpty) throw FormatException('目标 URL 缺少主机名', url);
  final port = u.hasPort ? u.port : (scheme == 'https' ? 443 : 80);
  if (port < 1 || port > 65535) {
    throw FormatException('目标端口必须在 1–65535 之间', url);
  }
  var path = u.path.isEmpty ? '/' : u.path;
  if (u.hasQuery) path += '?${u.query}';
  return (scheme: scheme, host: u.host, port: port, path: path);
}

String ipNote(String ip) {
  final a = InternetAddress.tryParse(ip);
  if (a == null) return '';
  if (a.type == InternetAddressType.IPv4) {
    final b = a.rawAddress;
    if (b[0] == 198 && (b[1] == 18 || b[1] == 19)) {
      return ' (FakeIP 段，疑似被 TUN/FakeDNS 接管)';
    }
    if (b[0] == 127) return ' (回环)';
    if (b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
        (b[0] == 192 && b[1] == 168)) {
      return ' (私网)';
    }
  } else if (a.isLoopback) {
    return ' (回环)';
  }
  return '';
}

bool isBinary(List<int> b) {
  if (b.isEmpty) return false;
  var ctrl = 0;
  for (final x in b) {
    if ((x < 32 && x != 9 && x != 10 && x != 13) || x == 127) ctrl++;
  }
  final bad = '\uFFFD'.allMatches(utf8.decode(b, allowMalformed: true)).length;
  return ctrl / b.length > 0.05 || bad / b.length > 0.02;
}

String hexDump(List<int> b, {String indent = ''}) {
  final sb = StringBuffer();
  for (var i = 0; i < b.length; i += 16) {
    final row = b.sublist(i, i + 16 > b.length ? b.length : i + 16);
    final hx = row
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join(' ')
        .padRight(47);
    final asc = String.fromCharCodes(
      row.map((x) => x >= 32 && x < 127 ? x : 46),
    );
    if (i > 0) sb.write('\n');
    sb.write('$indent${i.toRadixString(16).padLeft(6, '0')}  $hx  $asc');
  }
  return sb.toString();
}

/// Text view: normalize newlines, replace control chars with '·'.
String textView(List<int> b) {
  var s = utf8
      .decode(b, allowMalformed: true)
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final sb = StringBuffer();
  for (final r in s.runes) {
    if (r == 10 ||
        r == 9 ||
        (r >= 32 && r != 127 && !(r >= 0x80 && r < 0xA0))) {
      sb.writeCharCode(r);
    } else {
      sb.write('·');
    }
  }
  return sb.toString().trimRight();
}
