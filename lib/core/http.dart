// HTTP/1.1 request builder and incremental response parser (Content-Length / chunked / close-delimited).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'util.dart';

List<Uint8List> buildHttpRequest(
  String method,
  String host,
  int port,
  String path, {
  String extraHeaders = '',
  bool keepAlive = true,
  String scheme = 'http',
  List<int>? body,
}) {
  final def = scheme == 'https' ? 443 : 80;
  var hh = host.contains(':') ? '[$host]' : host;
  if (port != def) hh += ':$port';
  final headers = <String, String>{
    'host': 'Host: $hh',
    'user-agent': 'User-Agent: NetTestClient/1.0',
    'accept': 'Accept: */*',
    'connection': 'Connection: ${keepAlive ? 'keep-alive' : 'close'}',
  };
  for (final raw in const LineSplitter().convert(extraHeaders)) {
    final i = raw.indexOf(':');
    if (i > 0) headers[raw.substring(0, i).trim().toLowerCase()] = raw.trim();
  }
  if (body != null && body.isNotEmpty) {
    headers['content-length'] = 'Content-Length: ${body.length}';
  }
  return [
    Uint8List.fromList(latin1.encode('$method $path HTTP/1.1\r\n')),
    Uint8List.fromList(utf8.encode(headers.values.map((h) => '$h\r\n').join())),
    Uint8List.fromList(crlf),
    Uint8List.fromList(body ?? const []),
  ];
}

class HttpResp {
  HttpResp(this.status, this.code, this.headers, this.path, this.total)
    : tHead = now();
  final String status;
  final int code;
  final Map<String, String> headers;
  final String path;
  int? total;
  final double tHead;
  double tEnd = 0;
  int bodyLen = 0;
  int n = 0;
  bool incomplete = false;
  // download sink, owned by the session
  IOSink? sink;
  String? file, tempFile, saveKey;
  Future<void>? sinkDone;
  bool saveFailed = false;
}

class HttpResponseParser {
  Uint8List _buf = Uint8List(0);
  int _off = 0;
  String _state = 'head';
  int _remaining = 0;
  HttpResp? cur;
  final List<HttpResp> done = [];
  final List<bool> expectNoBody = [];
  final List<String> expectPaths = [];
  void Function(HttpResp r)? onHead;
  void Function(HttpResp r, Uint8List data)? onBody;

  int get _avail => _buf.length - _off;

  void _append(List<int> data) {
    if (_off > 0 && _off == _buf.length) {
      _buf = Uint8List.fromList(data);
      _off = 0;
      return;
    }
    final nb = Uint8List(_avail + data.length);
    nb.setRange(0, _avail, _buf, _off);
    nb.setRange(_avail, nb.length, data);
    _buf = nb;
    _off = 0;
  }

  Uint8List _take(int n) {
    final v = Uint8List.sublistView(_buf, _off, _off + n);
    _off += n;
    return v;
  }

  List<HttpResp> feed(List<int> data) {
    _append(data);
    final finished = <HttpResp>[];
    while (true) {
      if (_state == 'head') {
        final idx = indexOf(_buf, crlfcrlf, _off);
        if (idx < 0) break;
        final head = latin1.decode(_buf.sublist(_off, idx));
        _off = idx + 4;
        final lines = head.split('\r\n');
        final parts = lines[0].split(' ');
        final code = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
        final hdr = <String, String>{};
        for (final l in lines.skip(1)) {
          final i = l.indexOf(':');
          if (i > 0) {
            hdr[l.substring(0, i).trim().toLowerCase()] = l
                .substring(i + 1)
                .trim();
          }
        }
        if (code >= 100 && code < 200) continue; // interim
        final noBody = expectNoBody.isNotEmpty
            ? expectNoBody.removeAt(0)
            : false;
        final path = expectPaths.isNotEmpty ? expectPaths.removeAt(0) : '/';
        final chunked = (hdr['transfer-encoding'] ?? '').toLowerCase().contains(
          'chunked',
        );
        int? total = (!chunked && hdr.containsKey('content-length'))
            ? int.tryParse(hdr['content-length']!)
            : null;
        cur = HttpResp(lines[0], code, hdr, path, noBody ? 0 : total);
        if (noBody || code == 204 || code == 304) {
          cur!.total = 0;
          finished.add(_finish());
          continue;
        }
        onHead?.call(cur!);
        if (chunked) {
          _state = 'chunk_size';
        } else if (total != null) {
          _remaining = total;
          _state = 'length';
          if (_remaining == 0) finished.add(_finish());
        } else {
          _state = 'eof';
        }
      } else if (_state == 'length') {
        final take = _remaining < _avail ? _remaining : _avail;
        _add(_take(take));
        _remaining -= take;
        if (_remaining == 0) {
          finished.add(_finish());
        } else {
          break;
        }
      } else if (_state == 'chunk_size') {
        final idx = indexOf(_buf, crlf, _off);
        if (idx < 0) break;
        final line = latin1
            .decode(_buf.sublist(_off, idx))
            .split(';')[0]
            .trim();
        _off = idx + 2;
        final size = int.parse(line.isEmpty ? '0' : line, radix: 16);
        if (size == 0) {
          _state = 'trailer';
        } else {
          _remaining = size + 2;
          _state = 'chunk_data';
        }
      } else if (_state == 'chunk_data') {
        final take = _remaining < _avail ? _remaining : _avail;
        final dataPart = (_remaining - 2).clamp(0, take);
        final chunk = _take(take);
        _add(Uint8List.sublistView(chunk, 0, dataPart));
        _remaining -= take;
        if (_remaining == 0) {
          _state = 'chunk_size';
        } else {
          break;
        }
      } else if (_state == 'trailer') {
        final idx = indexOf(_buf, crlf, _off);
        if (idx < 0) break;
        final empty = idx == _off;
        _off = idx + 2;
        if (empty) finished.add(_finish());
      } else if (_state == 'eof') {
        _add(_take(_avail));
        break;
      }
    }
    return finished;
  }

  void _add(Uint8List d) {
    if (d.isEmpty) return;
    cur!.bodyLen += d.length;
    onBody?.call(cur!, d);
  }

  /// Connection closed: finish close-delimited body, or report a truncated one.
  ({List<HttpResp> finished, HttpResp? cut}) onEof() {
    if (cur != null && _state == 'eof') {
      return (finished: [_finish()], cut: null);
    }
    if (cur != null) {
      final r = cur!
        ..tEnd = now()
        ..incomplete = true;
      cur = null;
      return (finished: <HttpResp>[], cut: r);
    }
    return (finished: <HttpResp>[], cut: null);
  }

  HttpResp _finish() {
    final r = cur!..tEnd = now();
    done.add(r);
    cur = null;
    _state = 'head';
    return r;
  }
}

/// File name like curl -O: last path segment, default index.html.
String targetName(String path, [String suffix = '']) {
  var name = path.split('?')[0];
  while (name.endsWith('/')) {
    name = name.substring(0, name.length - 1);
  }
  name = name.split('/').last;
  try {
    name = Uri.decodeComponent(name);
  } catch (_) {}
  name = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
  if (name.isEmpty || name == '.' || name == '..') name = 'index.html';
  if (suffix.isNotEmpty) {
    final dot = name.lastIndexOf('.');
    name = dot > 0
        ? '${name.substring(0, dot)}$suffix${name.substring(dot)}'
        : '$name$suffix';
  }
  return name;
}
