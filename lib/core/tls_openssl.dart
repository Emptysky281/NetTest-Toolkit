// Windows manual TLS: OpenSSL 3 (libssl / libcrypto) driven through memory BIOs via dart:ffi.
// Same contract as the Android SSLEngine bridge (ManualTls.kt): the caller moves bytes over its own TCP
// socket; step() feeds buffered server bytes, advances the handshake and returns our next flight,
// stopping as soon as more server data is needed. Certificate checks use the Windows ROOT / CA stores.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _PV = Pointer<Void>;

// ---- libssl / libcrypto signatures
typedef _NoArgP = _PV Function();
typedef _PtoP = _PV Function(_PV);
typedef _PtoVoidN = Void Function(_PV);
typedef _PtoVoid = void Function(_PV);
typedef _PtoIntN = Int32 Function(_PV);
typedef _PtoInt = int Function(_PV);
typedef _PIntToIntN = Int32 Function(_PV, Int32);
typedef _PIntToInt = int Function(_PV, int);
typedef _PPPtoVoidN = Void Function(_PV, _PV, _PV);
typedef _PPPtoVoid = void Function(_PV, _PV, _PV);
typedef _PIntPtoVoidN = Void Function(_PV, Int32, _PV);
typedef _PIntPtoVoid = void Function(_PV, int, _PV);
typedef _PBufIntToIntN = Int32 Function(_PV, Pointer<Uint8>, Int32);
typedef _PBufIntToInt = int Function(_PV, Pointer<Uint8>, int);
typedef _PStrToIntN = Int32 Function(_PV, Pointer<Utf8>);
typedef _PStrToInt = int Function(_PV, Pointer<Utf8>);
typedef _PtoStrN = Pointer<Utf8> Function(_PV);
typedef _PtoStr = Pointer<Utf8> Function(_PV);
typedef _PtoLongN = Int64 Function(_PV);
typedef _PtoLong = int Function(_PV);
typedef _CtrlN = Int64 Function(_PV, Int32, Int64, _PV);
typedef _Ctrl = int Function(_PV, int, int, _PV);
typedef _ErrN = Uint64 Function();
typedef _Err = int Function();
typedef _ErrStrN = Void Function(Uint64, Pointer<Utf8>, IntPtr);
typedef _ErrStr = void Function(int, Pointer<Utf8>, int);
typedef _VerifyStrN = Pointer<Utf8> Function(Int64);
typedef _VerifyStr = Pointer<Utf8> Function(int);
typedef _D2iN = _PV Function(_PV, Pointer<Pointer<Uint8>>, Int64);
typedef _D2i = _PV Function(_PV, Pointer<Pointer<Uint8>>, int);
typedef _AlpnGetN = Void Function(
  _PV,
  Pointer<Pointer<Uint8>>,
  Pointer<Uint32>,
);
typedef _AlpnGet = void Function(_PV, Pointer<Pointer<Uint8>>, Pointer<Uint32>);
typedef _AlpnSetN = Int32 Function(_PV, Pointer<Uint8>, Uint32);
typedef _AlpnSet = int Function(_PV, Pointer<Uint8>, int);

// ---- crypt32 (Windows certificate stores)
typedef _OpenStoreN = _PV Function(_PV, Pointer<Utf16>);
typedef _OpenStore = _PV Function(_PV, Pointer<Utf16>);
typedef _EnumN = Pointer<_CertContext> Function(_PV, Pointer<_CertContext>);
typedef _Enum = Pointer<_CertContext> Function(_PV, Pointer<_CertContext>);
typedef _CloseStoreN = Int32 Function(_PV, Uint32);
typedef _CloseStore = int Function(_PV, int);

final class _CertContext extends Struct {
  @Uint32()
  external int dwCertEncodingType;
  external Pointer<Uint8> pbCertEncoded;
  @Uint32()
  external int cbCertEncoded;
  external _PV pCertInfo;
  external _PV hCertStore;
}

const _sslErrorWantRead = 2, _sslErrorWantWrite = 3, _sslErrorZeroReturn = 6;
const _sslCtrlSetTlsextHostname = 55, _tlsextNametypeHostName = 0;
const _sslVerifyNone = 0, _sslVerifyPeer = 1;
const _x509V0k = 0;

class _Lib {
  _Lib._(DynamicLibrary ssl, DynamicLibrary crypto)
    : ctxNew = ssl.lookupFunction<_PtoP, _PtoP>('SSL_CTX_new'),
      clientMethod = ssl.lookupFunction<_NoArgP, _NoArgP>('TLS_client_method'),
      ctxFree = ssl.lookupFunction<_PtoVoidN, _PtoVoid>('SSL_CTX_free'),
      ctxSetVerify = ssl.lookupFunction<_PIntPtoVoidN, _PIntPtoVoid>(
        'SSL_CTX_set_verify',
      ),
      ctxGetCertStore = ssl.lookupFunction<_PtoP, _PtoP>(
        'SSL_CTX_get_cert_store',
      ),
      sslNew = ssl.lookupFunction<_PtoP, _PtoP>('SSL_new'),
      sslFree = ssl.lookupFunction<_PtoVoidN, _PtoVoid>('SSL_free'),
      setBio = ssl.lookupFunction<_PPPtoVoidN, _PPPtoVoid>('SSL_set_bio'),
      setConnectState = ssl.lookupFunction<_PtoVoidN, _PtoVoid>(
        'SSL_set_connect_state',
      ),
      ctrl = ssl.lookupFunction<_CtrlN, _Ctrl>('SSL_ctrl'),
      set1Host = ssl.lookupFunction<_PStrToIntN, _PStrToInt>('SSL_set1_host'),
      setAlpn = ssl.lookupFunction<_AlpnSetN, _AlpnSet>('SSL_set_alpn_protos'),
      doHandshake = ssl.lookupFunction<_PtoIntN, _PtoInt>('SSL_do_handshake'),
      read = ssl.lookupFunction<_PBufIntToIntN, _PBufIntToInt>('SSL_read'),
      write = ssl.lookupFunction<_PBufIntToIntN, _PBufIntToInt>('SSL_write'),
      getError = ssl.lookupFunction<_PIntToIntN, _PIntToInt>('SSL_get_error'),
      isInitFinished = ssl.lookupFunction<_PtoIntN, _PtoInt>(
        'SSL_is_init_finished',
      ),
      getVersion = ssl.lookupFunction<_PtoStrN, _PtoStr>('SSL_get_version'),
      getCurrentCipher = ssl.lookupFunction<_PtoP, _PtoP>(
        'SSL_get_current_cipher',
      ),
      cipherName = ssl.lookupFunction<_PtoStrN, _PtoStr>('SSL_CIPHER_get_name'),
      getAlpn = ssl.lookupFunction<_AlpnGetN, _AlpnGet>(
        'SSL_get0_alpn_selected',
      ),
      getVerifyResult = ssl.lookupFunction<_PtoLongN, _PtoLong>(
        'SSL_get_verify_result',
      ),
      shutdown = ssl.lookupFunction<_PtoIntN, _PtoInt>('SSL_shutdown'),
      bioSMem = crypto.lookupFunction<_NoArgP, _NoArgP>('BIO_s_mem'),
      bioNew = crypto.lookupFunction<_PtoP, _PtoP>('BIO_new'),
      bioRead = crypto.lookupFunction<_PBufIntToIntN, _PBufIntToInt>(
        'BIO_read',
      ),
      bioWrite = crypto.lookupFunction<_PBufIntToIntN, _PBufIntToInt>(
        'BIO_write',
      ),
      bioCtrlPending = crypto.lookupFunction<_PtoLongN, _PtoLong>(
        'BIO_ctrl_pending',
      ),
      errGetError = crypto.lookupFunction<_ErrN, _Err>('ERR_get_error'),
      errErrorStringN = crypto.lookupFunction<_ErrStrN, _ErrStr>(
        'ERR_error_string_n',
      ),
      errClear = crypto.lookupFunction<Void Function(), void Function()>(
        'ERR_clear_error',
      ),
      verifyErrString = crypto.lookupFunction<_VerifyStrN, _VerifyStr>(
        'X509_verify_cert_error_string',
      ),
      d2iX509 = crypto.lookupFunction<_D2iN, _D2i>('d2i_X509'),
      x509Free = crypto.lookupFunction<_PtoVoidN, _PtoVoid>('X509_free'),
      storeAddCert = crypto
          .lookupFunction<Int32 Function(_PV, _PV), int Function(_PV, _PV)>(
            'X509_STORE_add_cert',
          );

  final _PV Function(_PV) ctxNew;
  final _PV Function() clientMethod;
  final void Function(_PV) ctxFree;
  final void Function(_PV, int, _PV) ctxSetVerify;
  final _PV Function(_PV) ctxGetCertStore;
  final _PV Function(_PV) sslNew;
  final void Function(_PV) sslFree;
  final void Function(_PV, _PV, _PV) setBio;
  final void Function(_PV) setConnectState;
  final int Function(_PV, int, int, _PV) ctrl;
  final int Function(_PV, Pointer<Utf8>) set1Host;
  final int Function(_PV, Pointer<Uint8>, int) setAlpn;
  final int Function(_PV) doHandshake;
  final int Function(_PV, Pointer<Uint8>, int) read;
  final int Function(_PV, Pointer<Uint8>, int) write;
  final int Function(_PV, int) getError;
  final int Function(_PV) isInitFinished;
  final Pointer<Utf8> Function(_PV) getVersion;
  final _PV Function(_PV) getCurrentCipher;
  final Pointer<Utf8> Function(_PV) cipherName;
  final void Function(_PV, Pointer<Pointer<Uint8>>, Pointer<Uint32>) getAlpn;
  final int Function(_PV) getVerifyResult;
  final int Function(_PV) shutdown;
  final _PV Function() bioSMem;
  final _PV Function(_PV) bioNew;
  final int Function(_PV, Pointer<Uint8>, int) bioRead;
  final int Function(_PV, Pointer<Uint8>, int) bioWrite;
  final int Function(_PV) bioCtrlPending;
  final int Function() errGetError;
  final void Function(int, Pointer<Utf8>, int) errErrorStringN;
  final void Function() errClear;
  final Pointer<Utf8> Function(int) verifyErrString;
  final _PV Function(_PV, Pointer<Pointer<Uint8>>, int) d2iX509;
  final void Function(_PV) x509Free;
  final int Function(_PV, _PV) storeAddCert;

  static _Lib? _inst;
  static String? loadError;

  /// libssl-3*.dll / libcrypto-3*.dll next to the exe (bundled by windows/CMakeLists.txt).
  static _Lib? get instance {
    if (_inst != null || loadError != null) return _inst;
    // next to the exe; NETTEST_OPENSSL_DIR lets host tests (flutter_tester.exe) point at windows/openssl
    final dirs = [
      if (Platform.environment['NETTEST_OPENSSL_DIR'] case final d?
          when d.isNotEmpty)
        d,
      File(Platform.resolvedExecutable).parent.path,
    ];
    DynamicLibrary? open(List<String> names) {
      for (final n in names) {
        for (final p in [
          for (final d in dirs) '$d${Platform.pathSeparator}$n',
          n,
        ]) {
          try {
            return DynamicLibrary.open(p);
          } catch (_) {}
        }
      }
      return null;
    }

    final crypto = open(['libcrypto-3-x64.dll', 'libcrypto-3.dll']);
    final ssl = open(['libssl-3-x64.dll', 'libssl-3.dll']);
    if (crypto == null || ssl == null) {
      loadError = '找不到 OpenSSL（libssl-3 / libcrypto-3）';
      return null;
    }
    try {
      _inst = _Lib._(ssl, crypto);
    } catch (e) {
      loadError = 'OpenSSL 加载失败: $e';
    }
    return _inst;
  }
}

/// System trust: copy the Windows ROOT and CA stores into the OpenSSL X509_STORE once per context.
void _loadWindowsRoots(_Lib l, _PV store) {
  final crypt = DynamicLibrary.open('crypt32.dll');
  final open = crypt.lookupFunction<_OpenStoreN, _OpenStore>(
    'CertOpenSystemStoreW',
  );
  final enumCerts = crypt.lookupFunction<_EnumN, _Enum>(
    'CertEnumCertificatesInStore',
  );
  final close = crypt.lookupFunction<_CloseStoreN, _CloseStore>(
    'CertCloseStore',
  );
  for (final name in ['ROOT', 'CA']) {
    final n = name.toNativeUtf16();
    final h = open(nullptr, n);
    calloc.free(n);
    if (h == nullptr) continue;
    var c = enumCerts(h, nullptr);
    final pp = calloc<Pointer<Uint8>>();
    while (c != nullptr) {
      pp.value = c.ref.pbCertEncoded;
      final x = l.d2iX509(nullptr, pp, c.ref.cbCertEncoded);
      if (x != nullptr) {
        l.storeAddCert(store, x); // duplicates are rejected harmlessly
        l.x509Free(x);
      }
      c = enumCerts(h, c);
    }
    calloc.free(pp);
    close(h, 0);
  }
  l.errClear(); // "cert already in hash table" noise from duplicates
}

Uint8List _alpnWire(List<String> protos) {
  final b = BytesBuilder();
  for (final p in protos) {
    final e = utf8.encode(p);
    if (e.isEmpty || e.length > 255) continue;
    b.addByte(e.length);
    b.add(e);
  }
  return b.toBytes();
}

bool _isIp(String s) => InternetAddress.tryParse(s) != null;

class OpenSslTls {
  OpenSslTls._(
    this._l,
    this._ctx,
    this._ssl,
    this._rbio,
    this._wbio,
    this.verify,
  );
  final _Lib _l;
  final _PV _ctx, _ssl, _rbio, _wbio;
  final bool verify;
  bool _done = false, _closed = false, _freed = false;

  static final Map<int, OpenSslTls> _sessions = {};
  static int _nextId = 1;

  static String? get unavailable =>
      _Lib.instance == null ? _Lib.loadError : null;

  static int begin(
    String host,
    int port,
    String sni,
    bool verify,
    List<String> alpn,
  ) {
    final l = _Lib.instance;
    if (l == null) throw StateError(_Lib.loadError ?? 'OpenSSL 不可用');
    final ctx = l.ctxNew(l.clientMethod());
    if (ctx == nullptr) throw StateError('SSL_CTX_new 失败: ${_errs(l)}');
    if (verify) {
      _loadWindowsRoots(l, l.ctxGetCertStore(ctx));
      l.ctxSetVerify(ctx, _sslVerifyPeer, nullptr);
    } else {
      l.ctxSetVerify(ctx, _sslVerifyNone, nullptr);
    }
    final ssl = l.sslNew(ctx);
    final rbio = l.bioNew(l.bioSMem()), wbio = l.bioNew(l.bioSMem());
    l.setBio(ssl, rbio, wbio); // ssl owns both BIOs now
    l.setConnectState(ssl);
    final peer = sni.isNotEmpty ? sni : host;
    if (sni.isNotEmpty && !_isIp(sni)) {
      final s = sni.toNativeUtf8();
      l.ctrl(ssl, _sslCtrlSetTlsextHostname, _tlsextNametypeHostName, s.cast());
      calloc.free(s);
    }
    if (verify) {
      // hostname (or IP) check, like ssl.check_hostname / endpointIdentificationAlgorithm
      final h = peer.toNativeUtf8();
      l.set1Host(ssl, h);
      calloc.free(h);
    }
    final wire = _alpnWire(alpn);
    if (wire.isNotEmpty) {
      final p = calloc<Uint8>(wire.length)
        ..asTypedList(wire.length).setAll(0, wire);
      l.setAlpn(ssl, p, wire.length);
      calloc.free(p);
    }
    final id = _nextId++;
    _sessions[id] = OpenSslTls._(l, ctx, ssl, rbio, wbio, verify);
    return id;
  }

  // A call can arrive after tlsClose (e.g. a decrypt queued behind the socket's close event). Like the
  // Android bridge, report it as an error result instead of throwing into the caller.
  static Map<String, Object?> _call(
    int id,
    Map<String, Object?> Function(OpenSslTls t) f,
  ) {
    final t = _sessions[id];
    if (t == null) {
      return {
        'error': 'TLS 会话不存在: $id',
        'out': Uint8List(0),
        'plain': Uint8List(0),
      };
    }
    try {
      return f(t);
    } catch (e) {
      return {'error': '$e', 'out': Uint8List(0), 'plain': Uint8List(0)};
    }
  }

  static Map<String, Object?> step(int id, Uint8List incoming) =>
      _call(id, (t) => t._step(incoming));
  static Map<String, Object?> decrypt(int id, Uint8List data) =>
      _call(id, (t) => t._decrypt(data));
  static Map<String, Object?> encrypt(int id, Uint8List data) =>
      _call(id, (t) => t._encrypt(data));
  static void close(int id) => _sessions.remove(id)?._free();

  static String _errs(_Lib l) {
    final parts = <String>[];
    final buf = calloc<Uint8>(256).cast<Utf8>();
    for (var e = l.errGetError(); e != 0; e = l.errGetError()) {
      l.errErrorStringN(e, buf, 256);
      parts.add(buf.toDartString());
    }
    calloc.free(buf);
    return parts.isEmpty ? '' : parts.join('; ');
  }

  void _feed(Uint8List data) {
    if (data.isEmpty) return;
    final p = calloc<Uint8>(data.length)
      ..asTypedList(data.length).setAll(0, data);
    _l.bioWrite(_rbio, p, data.length);
    calloc.free(p);
  }

  Uint8List _takeOut() {
    final n = _l.bioCtrlPending(_wbio);
    if (n <= 0) return Uint8List(0);
    final p = calloc<Uint8>(n);
    final got = _l.bioRead(_wbio, p, n);
    final out = Uint8List.fromList(p.asTypedList(got > 0 ? got : 0));
    calloc.free(p);
    return out;
  }

  /// Read every decrypted byte currently available. TLS 1.3 session tickets are absorbed here.
  Uint8List _drainApp() {
    final b = BytesBuilder();
    final p = calloc<Uint8>(16384);
    while (true) {
      final n = _l.read(_ssl, p, 16384);
      if (n > 0) {
        b.add(p.asTypedList(n));
        continue;
      }
      final e = _l.getError(_ssl, n);
      if (e == _sslErrorZeroReturn) _closed = true;
      if (e != _sslErrorWantRead &&
          e != _sslErrorWantWrite &&
          e != _sslErrorZeroReturn) {
        final msg = _errs(_l);
        calloc.free(p);
        throw StateError(msg.isEmpty ? 'SSL_read 失败 (code $e)' : msg);
      }
      break;
    }
    calloc.free(p);
    return b.toBytes();
  }

  String _handshakeError(int e) {
    var msg = _errs(_l);
    if (verify) {
      final v = _l.getVerifyResult(_ssl);
      if (v != _x509V0k) {
        final r = _l.verifyErrString(v).toDartString();
        msg = msg.isEmpty
            ? 'CERTIFICATE_VERIFY_FAILED: $r'
            : 'CERTIFICATE_VERIFY_FAILED: $r ($msg)';
      }
    }
    return msg.isEmpty ? 'SSL_do_handshake 失败 (code $e)' : msg;
  }

  Map<String, Object?> _result(Uint8List out, Uint8List plain) {
    final m = <String, Object?>{
      'out': out,
      'plain': plain,
      'done': _done,
      'closed': _closed,
    };
    if (_done) {
      m['protocol'] = _l.getVersion(_ssl).toDartString();
      final c = _l.getCurrentCipher(_ssl);
      m['cipher'] = c == nullptr ? null : _l.cipherName(c).toDartString();
      final pp = calloc<Pointer<Uint8>>(), pl = calloc<Uint32>();
      _l.getAlpn(_ssl, pp, pl);
      m['alpn'] = pl.value == 0
          ? null
          : utf8.decode(pp.value.asTypedList(pl.value), allowMalformed: true);
      calloc.free(pp);
      calloc.free(pl);
    }
    return m;
  }

  Map<String, Object?> _step(Uint8List incoming) {
    _feed(incoming);
    if (!_done) {
      _l.errClear();
      final r = _l.doHandshake(_ssl);
      if (r == 1 || _l.isInitFinished(_ssl) == 1) {
        _done = true;
      } else {
        final e = _l.getError(_ssl, r);
        if (e != _sslErrorWantRead && e != _sslErrorWantWrite) {
          // an alert the engine generated is in the write BIO; send it like the Android bridge does
          return {
            'out': _takeOut(),
            'error': _handshakeError(e),
            'done': false,
          };
        }
      }
    }
    try {
      final plain = _done ? _drainApp() : Uint8List(0);
      return _result(_takeOut(), plain);
    } catch (e) {
      return {'out': _takeOut(), 'error': '$e', 'done': _done};
    }
  }

  Map<String, Object?> _decrypt(Uint8List data) {
    _feed(data);
    try {
      return _result(Uint8List(0), _drainApp());
    } catch (e) {
      return {'error': '$e', 'plain': Uint8List(0)};
    }
  }

  Map<String, Object?> _encrypt(Uint8List data) {
    if (_closed) return {'error': 'TLS 已关闭', 'out': Uint8List(0)};
    final p = calloc<Uint8>(data.isEmpty ? 1 : data.length)
      ..asTypedList(data.length).setAll(0, data);
    var off = 0;
    String? err;
    while (off < data.length) {
      final n = _l.write(_ssl, p + off, data.length - off);
      if (n <= 0) {
        err = _errs(_l);
        if (err.isEmpty) err = 'SSL_write 失败 (code ${_l.getError(_ssl, n)})';
        break;
      }
      off += n;
    }
    calloc.free(p);
    return err != null
        ? {'error': err, 'out': Uint8List(0)}
        : {'out': _takeOut()};
  }

  void _free() {
    if (_freed) return;
    _freed = true;
    _l.sslFree(_ssl); // also frees both BIOs
    _l.ctxFree(_ctx);
  }
}
