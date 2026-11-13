import 'package:flutter/material.dart';

import 'app_state.dart';
import 'widgets.dart';

/// Manual TCP / TLS / HTTP stages.
class StepPage extends StatefulWidget {
  const StepPage(this.st, {super.key});
  final AppState st;
  @override
  State<StepPage> createState() => _StepPageState();
}

class _StepPageState extends State<StepPage> {
  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final o = st.step;
    Widget btn(
      String t,
      VoidCallback f, {
      bool primary = false,
      bool allowBusy = false,
    }) {
      final handler = st.stepBusy && !allowBusy ? null : f;
      return primary
          ? FilledButton.tonal(onPressed: handler, child: Text(t))
          : OutlinedButton(onPressed: handler, child: Text(t));
    }

    return ValueListenableBuilder(
      valueListenable: st.status,
      builder: (context, _, _) => SplitPage(
        st: st,
        logSrc: LogSrc.step,
        maxFraction: 0.58,
        top: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PageUrl(st, o.url, (v) => o.url = v.trim()),
              const SizedBox(height: 8),
              ValueListenableBuilder(
                valueListenable: st.status,
                builder: (c, _, _) {
                  final txt = st.stepStateText();
                  final ok = txt.contains('established');
                  // after ① the steps use the URL this connection was opened with
                  final conn = st.stepSess == null
                      ? ''
                      : '  ·  已连接 ${st.stepUrl}';
                  return Row(
                    children: [
                      Icon(
                        ok ? Icons.link : Icons.link_off,
                        size: 18,
                        color: ok ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '状态: $txt$conn',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: ok
                                ? Colors.green.shade800
                                : Colors.red.shade700,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              wrapRow([
                Drop(
                  '方法',
                  o.method,
                  httpMethods,
                  (v) => o.method = v,
                  width: 110,
                ),
                Check(
                  'keep-alive',
                  o.keepAlive,
                  (v) => setState(() => o.keepAlive = v),
                ),
                TextIn('TLS SNI(空=URL主机)', o.sni, (v) => o.sni = v, width: 170),
                TextIn('ALPN', o.alpn, (v) => o.alpn = v, width: 100),
                Check(
                  '校验证书',
                  st.stepVerify,
                  (v) => setState(() => o.verify = v),
                ),
                TextButton(
                  onPressed: o.verify == null
                      ? null
                      : () => setState(() => o.verify = null),
                  child: Text(o.verify == null ? '跟随全局设置' : '恢复跟随全局'),
                ),
                Check(
                  '握手包按分片拆分',
                  o.fragHello,
                  (v) => setState(() => o.fragHello = v),
                ),
                NumField(
                  '分片B',
                  o.chunk,
                  (v) => o.chunk = v.toInt(),
                  isInt: true,
                  min: 1,
                  max: 65535,
                  width: 80,
                ),
                NumField(
                  '间隔(s)',
                  o.chunkDelay,
                  (v) => o.chunkDelay = v.toDouble(),
                  max: 30,
                  width: 80,
                ),
              ]),
              const SizedBox(height: 12),
              const Text(
                'TCP / TLS',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 4),
              wrapRow([
                btn('① TCP 握手', st.stepConnect, primary: true),
                btn('② TLS 发 ClientHello', () => st.stepTlsHello(context)),
                btn('③ TLS 继续握手', st.stepTlsNext),
              ]),
              const SizedBox(height: 10),
              const Text(
                'HTTP',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 4),
              wrapRow([
                btn('④ 请求行', () => st.stepSend(0)),
                btn('⑤ 请求头', () => st.stepSend(1)),
                btn('⑥ 空行', () => st.stepSend(2)),
                btn('一次发完整请求', () => st.stepSend(null), primary: true),
                btn('分片发完整请求', st.stepChunked),
              ]),
              const SizedBox(height: 12),
              PayloadField(
                st,
                r'自定义载荷(支持 \r \n \t \xNN)',
                o.raw,
                (v) => o.raw = v,
                hint: r'如 GET / HTTP/1.1\r\nHost: example.com\r\n\r\n',
              ),
              wrapRow([
                Check(
                  '绕过 TLS 直接发原始字节',
                  o.rawBypassTls,
                  (v) => setState(() => o.rawBypassTls = v),
                ),
                btn('发送', st.stepRaw),
              ]),
              const SizedBox(height: 10),
              const Text(
                '关闭',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 4),
              wrapRow([
                btn('半关闭(FIN)', () => st.stepClose('half'), allowBusy: true),
                btn('正常关闭', () => st.stepClose('fin'), allowBusy: true),
                btn('强制关闭(RST)', () => st.stepClose('rst'), allowBusy: true),
              ]),
              const SizedBox(height: 8),
              TextIn(
                '附加请求头',
                o.headers,
                (v) => o.headers = v,
                lines: 2,
                mono: true,
              ),
              const SizedBox(height: 8),
              const Text(
                '流程：① → (HTTPS: ② 发 ClientHello 等服务器回包 → ③ 发客户端 Finished，TLS1.2 收到回包后再点一次 ③) → ④⑤⑥。'
                '① 由系统完成 SYN/SYN-ACK/ACK，无法单独拆开。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LogPage extends StatefulWidget {
  const LogPage(this.st, {super.key});
  final AppState st;
  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    void toggle(VoidCallback f) {
      setState(f);
      st.logVersion.value++;
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: wrapRow([
            Check(
              '显示载荷',
              st.showPayload,
              (v) => toggle(() => st.showPayload = v),
            ),
            Check('HEX', st.showHex, (v) => toggle(() => st.showHex = v)),
            Check(
              '自动滚动',
              st.autoscroll,
              (v) => toggle(() => st.autoscroll = v),
            ),
            NumField(
              '载荷最多显示B',
              st.payloadMax,
              (v) => st.payloadMax = v.toInt(),
              isInt: true,
              min: payloadKeepMin,
              max: payloadKeepMax,
              width: 120,
            ),
            TextButton(onPressed: st.saveLog, child: const Text('保存日志')),
            TextButton(onPressed: st.clearLog, child: const Text('清空')),
            ValueListenableBuilder(
              valueListenable: st.logVersion,
              builder: (c, _, _) => Text(
                '${st.logs.length} 条${st.logs.length >= logKeep ? '(只保留最近 $logKeep 条)' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: LogView(st)),
      ],
    );
  }
}
