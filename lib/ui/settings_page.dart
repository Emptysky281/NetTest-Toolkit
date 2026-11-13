import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/proxy.dart';
import 'app_state.dart';
import 'widgets.dart';

/// Shared target / proxy / port / save settings.
class SettingsPage extends StatefulWidget {
  const SettingsPage(this.st, {super.key});
  final AppState st;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final s = widget.st.settings;
    final p = s.proxy;
    void set(VoidCallback f) {
      setState(f);
      widget.st.status.value++;
    }

    return ValueListenableBuilder(
      valueListenable: widget.st.status,
      builder: (c, _, _) => ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          section('URL 历史', [
            Text(
              '目标 URL 在单连接、多连接、分阶段各页分别填写；三个页面共用这份历史'
              '（${widget.st.history.length} 条，最多 20 条，运行时自动记入）。',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            TextButton.icon(
              onPressed: widget.st.history.isEmpty
                  ? null
                  : () async {
                      if (await confirm(
                        context,
                        '清空 URL 历史',
                        '删除全部 ${widget.st.history.length} 条历史 URL？各页已填写的 URL 不受影响。',
                      )) {
                        await widget.st.clearHistory();
                      }
                    },
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('清空 URL 历史'),
            ),
          ]),
          section('超时与证书', [
            wrapRow([
              NumField(
                '连接超时(s)',
                s.connectTimeout,
                (v) => s.connectTimeout = v.toDouble(),
                max: 600,
                width: 110,
              ),
              NumField(
                '回包超时(s)',
                s.timeout,
                (v) => s.timeout = v.toDouble(),
                max: 86400,
                width: 110,
              ),
              Check('TCP_NODELAY', s.nodelay, (v) => set(() => s.nodelay = v)),
              Check(
                '强制校验证书',
                s.verifyCerts,
                (v) => set(() => s.verifyCerts = v),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              '连接超时：DNS、TCP 三次握手、代理和 TLS 握手的时限。填 0 表示本程序不限时，'
              '由系统决定（对方不回 SYN-ACK 时，系统会按协议自动重传 SYN，'
              '${_win ? 'Windows 默认约 21 秒' : 'Android 默认约 2 分钟'}后放弃）。\n'
              '回包超时：连接建立后，连续多少秒收不到任何数据才判定超时并关闭。填 0 表示一直等待，连接保持不断开；'
              '同时会把 ${_win ? 'TCP_MAXRT' : 'TCP_USER_TIMEOUT'} 设为不限，对方不确认时系统持续重传而不自行断开。'
              '等待期间只被动显示进度，不发任何探测包。',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 4),
            Text(
              s.verifyCerts
                  ? 'HTTPS 会严格校验证书链、有效期与主机名，自签名/过期/域名不匹配的证书会握手失败。'
                  : '默认不校验证书：自签名、过期、域名不匹配的证书都能连上（每张证书的信息仍会记录到日志）。'
                        '需要严格校验时勾选「强制校验证书」。',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ]),
          section('出站方式', [
            wrapRow([
              Drop(
                '模式',
                p.mode,
                proxyModes,
                (v) => set(() => p.mode = v),
                width: 130,
              ),
              if (p.mode == 'socks5' || p.mode == 'http') ...[
                TextIn('代理地址', p.host, (v) => p.host = v.trim(), width: 150),
                NumField(
                  '端口',
                  p.port,
                  (v) => p.port = v.toInt(),
                  isInt: true,
                  min: 1,
                  max: 65535,
                  width: 90,
                ),
                TextIn('用户名', p.user, (v) => p.user = v, width: 110),
                TextIn(
                  '密码',
                  p.password,
                  (v) => p.password = v,
                  width: 110,
                  obscure: true,
                ),
              ],
              if (p.mode == 'socks5')
                Check(
                  'SOCKS 远端解析',
                  p.remoteDns,
                  (v) => set(() => p.remoteDns = v),
                ),
            ]),
            const SizedBox(height: 6),
            Text(
              _modeHelp(p),
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            if (p.mode == 'system')
              TextButton.icon(
                icon: const Icon(Icons.search, size: 18),
                label: const Text('检测系统代理'),
                onPressed: () async {
                  final r = await ProxyConfig(mode: 'system').resolved();
                  widget.st.toast(
                    r.mode == 'direct'
                        ? (_win
                              ? '未启用 Windows 系统代理，将直连（TUN 模式不依赖系统代理）'
                              : '未设置系统(Wi-Fi)代理，将直连')
                        : '系统代理: ${r.describe()}',
                  );
                },
              ),
          ]),
          section('本地端口', [
            wrapRow([
              Check('固定本地端口段', s.bindOn, (v) => set(() => s.bindOn = v)),
              NumField(
                '起',
                s.bindLo,
                (v) => s.bindLo = v.toInt(),
                isInt: true,
                min: 1024,
                max: 65535,
                width: 90,
              ),
              NumField(
                '止',
                s.bindHi,
                (v) => s.bindHi = v.toInt(),
                isInt: true,
                min: 1024,
                max: 65535,
                width: 90,
              ),
              TextButton(
                onPressed: () {
                  // Windows captures with Wireshark; Android with tcpdump / PCAPdroid
                  final f = _win
                      ? 'tcp.port in {${s.bindLo}..${s.bindHi}}'
                      : 'tcp portrange ${s.bindLo}-${s.bindHi}';
                  Clipboard.setData(ClipboardData(text: f));
                  widget.st.toast('已复制抓包过滤器: $f');
                },
                child: Text(_win ? '复制 Wireshark 过滤器' : '复制抓包过滤器'),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              _win
                  ? '所有连接使用该段的本地端口，抓包时按端口过滤即可只看本程序。TUN 模式抓 TUN 虚拟网卡；'
                        'socks/http 代理模式抓 Npcap Loopback Adapter。端口被占用（如 TIME_WAIT）时自动换下一个。'
                  : '所有连接使用该段的本地端口，抓包时按端口过滤即可只看本程序。tcpdump/PCAPdroid 用 "tcp portrange 起-止"，'
                        'Wireshark 用 tcp.port in {起..止}。',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ]),
          section('保存', [
            Check(
              '保存响应正文(同 curl -O 按 URL 文件名)',
              s.saveOn,
              (v) => set(() => s.saveOn = v),
            ),
            const SizedBox(height: 6),
            TextIn('保存目录', s.saveDir, (v) => s.saveDir = v.trim()),
            if (_win)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton.icon(
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('打开文件夹'),
                  onPressed: () async {
                    final d = s.saveDir.trim();
                    if (d.isEmpty) return widget.st.toast('保存目录为空');
                    try {
                      Directory(d).createSync(recursive: true);
                      await Process.run('explorer', [d]);
                    } catch (e) {
                      widget.st.toast('无法打开: $e');
                    }
                  },
                ),
              ),
            const SizedBox(height: 4),
            Text(
              _win
                  ? '默认在「文档\\NetTest\\downloads」；多连接/多请求追加 _c连接ID_r序号；中途断开存为 *.incomplete。'
                  : '默认在 Android/data/com.nettest.nettest/files/downloads，可用文件管理器或 adb pull 取出；'
                        '多连接/多请求追加 _c连接ID_r序号；中途断开存为 *.incomplete。',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ]),
        ],
      ),
    );
  }

  static bool get _win => Platform.isWindows;

  String _modeHelp(ProxyConfig p) => switch (p.mode) {
    'direct' =>
      _win
          ? '普通系统 socket。v2rayN / Xray 的 TUN 模式会透明劫持；DNS 落在 198.18.0.0/15 时日志会提示 FakeIP。'
          : '普通 socket。v2rayNG / Xray 的 VPN(TUN) 模式会透明劫持（注意不要把本应用加入分应用代理的"绕过"列表）；'
                'DNS 落在 198.18.0.0/15 时日志会提示 FakeIP。',
    'socks5' =>
      _win
          ? '指向 Xray / v2rayN 本地 socks 入站，如 127.0.0.1:10808。'
          : '指向 Xray / v2rayNG 本地 socks 入站，如 127.0.0.1:10808。',
    'http' => '指向本地 http 入站，走 HTTP CONNECT。',
    _ =>
      _win
          ? '读取 Windows 系统代理设置（http 或 socks），未启用时直连。'
          : '读取系统(Wi-Fi)全局 HTTP 代理设置，未设置时直连。',
  };
}
