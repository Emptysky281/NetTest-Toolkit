// Reassemble TLS records from one direction of a byte stream and describe them.
import 'dart:convert';
import 'dart:typed_data';

const tlsCt = {
  20: 'ChangeCipherSpec',
  21: 'Alert',
  22: 'Handshake',
  23: 'ApplicationData',
};
const tlsHs = {
  1: 'ClientHello',
  2: 'ServerHello',
  4: 'NewSessionTicket',
  8: 'EncryptedExtensions',
  11: 'Certificate',
  12: 'ServerKeyExchange',
  13: 'CertificateRequest',
  14: 'ServerHelloDone',
  15: 'CertificateVerify',
  16: 'ClientKeyExchange',
  20: 'Finished',
};
const _ver = {
  0x0301: 'TLS1.0',
  0x0302: 'TLS1.1',
  0x0303: 'TLS1.2',
  0x0304: 'TLS1.3',
};

int _u16(List<int> b, int i) => (b[i] << 8) | b[i + 1];

Iterable<(int, List<int>)> _exts(List<int> b, int i) sync* {
  final end = i + 2 + _u16(b, i);
  i += 2;
  while (i + 4 <= end && i + 4 <= b.length) {
    final et = _u16(b, i), el = _u16(b, i + 2);
    yield (et, b.sublist(i + 4, (i + 4 + el).clamp(0, b.length)));
    i += 4 + el;
  }
}

String helloInfo(int type, List<int> b) {
  try {
    var i = 2 + 32;
    i += 1 + b[i];
    if (type == 1) {
      i += 2 + _u16(b, i);
      i += 1 + b[i];
      final info = <String>[];
      for (final (et, d) in _exts(b, i)) {
        if (et == 0 && d.length > 5) {
          info.add(
            'SNI=${ascii.decode(d.sublist(5, 5 + _u16(d, 3)), allowInvalid: true)}',
          );
        }
        if (et == 16 && d.length > 3) {
          info.add(
            'ALPN=${ascii.decode(d.sublist(3, 3 + d[2]), allowInvalid: true)}',
          );
        }
      }
      return info.join(' ');
    }
    final cipher = _u16(b, i);
    i += 3;
    var ver = _ver[_u16(b, 0)] ?? '?';
    for (final (et, d) in _exts(b, i)) {
      if (et == 43 && d.length >= 2) ver = _ver[_u16(d, 0)] ?? ver;
    }
    return 'version=$ver cipher=0x${cipher.toRadixString(16).padLeft(4, '0')}';
  } catch (_) {
    return '';
  }
}

class TlsRecordView {
  final BytesBuilder _buf = BytesBuilder(copy: true);
  bool encrypted = false;

  List<String> feed(List<int> data) {
    _buf.add(data);
    var b = _buf.takeBytes();
    final out = <String>[];
    var i = 0;
    while (b.length - i >= 5) {
      final ct = b[i], ln = _u16(b, i + 3);
      if (!tlsCt.containsKey(ct)) {
        out.add('非 TLS 数据 ${b.length - i}B');
        i = b.length;
        break;
      }
      if (b.length - i < 5 + ln) break;
      final body = Uint8List.sublistView(b, i + 5, i + 5 + ln);
      i += 5 + ln;
      var desc = '${tlsCt[ct]} len=$ln';
      if (ct == 20) {
        encrypted = true;
      } else if (ct == 23) {
        desc += ' (加密)';
      } else if (ct == 21) {
        desc += encrypted || body.length < 2
            ? ' (已加密)'
            : ' level=${body[0]} desc=${body[1]}';
      } else if (ct == 22 && encrypted) {
        desc += ' (已加密，通常是 Finished)';
      } else if (ct == 22) {
        final msgs = <String>[];
        var j = 0;
        while (j + 4 <= body.length) {
          final ht = body[j],
              hl = (body[j + 1] << 16) | (body[j + 2] << 8) | body[j + 3];
          var name = tlsHs[ht] ?? 'type$ht';
          if (ht == 1 || ht == 2) {
            name =
                '$name ${helloInfo(ht, body.sublist(j + 4, (j + 4 + hl).clamp(0, body.length)))}'
                    .trim();
          }
          msgs.add(name);
          j += 4 + hl;
        }
        desc += ': ${msgs.join(', ')}';
      }
      out.add(desc);
    }
    if (i < b.length) _buf.add(Uint8List.sublistView(b, i));
    return out;
  }
}
