import 'package:flutter/material.dart';

import 'app_state.dart';
import 'widgets.dart';

/// HTTP request options shared by single and multi pages.
class HttpOptsForm extends StatefulWidget {
  const HttpOptsForm(this.st, this.o, {super.key});
  final AppState st;
  final HttpOpts o;
  @override
  State<HttpOptsForm> createState() => _HttpOptsFormState();
}

class _HttpOptsFormState extends State<HttpOptsForm> {
  @override
  Widget build(BuildContext context) {
    final o = widget.o;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        wrapRow([
          Drop('方法', o.method, httpMethods, (v) => o.method = v, width: 110),
          Check(
            'keep-alive',
            o.keepAlive,
            (v) => setState(() => o.keepAlive = v),
          ),
          NumField(
            '每连接请求数',
            o.requests,
            (v) => o.requests = v.toInt(),
            isInt: true,
            min: 1,
            max: 1000,
            width: 110,
          ),
          NumField(
            '请求间隔(s)',
            o.interval,
            (v) => o.interval = v.toDouble(),
            max: 60,
            width: 100,
          ),
          NumField(
            '保持(s)',
            o.hold,
            (v) => o.hold = v.toDouble(),
            max: 3600,
            width: 90,
          ),
          Check('请求分段发送', o.split, (v) => setState(() => o.split = v)),
          if (o.split)
            NumField(
              '段间延迟(s)',
              o.splitDelay,
              (v) => o.splitDelay = v.toDouble(),
              max: 30,
              width: 100,
            ),
        ]),
        const SizedBox(height: 10),
        TextIn(
          '附加请求头(每行一个，可覆盖默认)',
          o.headers,
          (v) => o.headers = v,
          lines: 3,
          mono: true,
          hint: 'User-Agent: curl/8.0',
        ),
        const SizedBox(height: 10),
        PayloadField(
          widget.st,
          r'自定义载荷(作为请求正文发送，支持 \r \n \t \xNN)',
          o.payload,
          (v) => o.payload = v,
          hint: 'k1=v1&k2=v2，右侧按钮选历史',
        ),
      ],
    );
  }
}

class SinglePage extends StatelessWidget {
  const SinglePage(this.st, {super.key});
  final AppState st;
  @override
  Widget build(BuildContext context) => SplitPage(
    st: st,
    logSrc: LogSrc.single,
    top: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageUrl(st, st.single.url, (v) => st.single.url = v.trim()),
          const SizedBox(height: 10),
          HttpOptsForm(st, st.single),
          const SizedBox(height: 4),
          _NoTlsCheck(st, single: true),
        ],
      ),
    ),
    actions: ValueListenableBuilder(
      valueListenable: st.status,
      builder: (c, _, _) => wrapRow([
        FilledButton.icon(
          onPressed: st.singleBusy ? null : () => st.runSingle(),
          icon: const Icon(Icons.play_arrow),
          label: const Text('建立连接并请求'),
        ),
        OutlinedButton(
          onPressed: st.singleBusy
              ? null
              : () => st.runSingle(connectOnly: true),
          child: const Text('仅建立 TCP'),
        ),
        OutlinedButton.icon(
          onPressed: st.singleBusy ? () => st.stop(LogSrc.single) : null,
          icon: const Icon(Icons.stop),
          label: const Text('停止'),
        ),
      ]),
    ),
  );
}

/// "Send right after the TCP handshake, no TLS" option, shared by the single and multi pages.
class _NoTlsCheck extends StatefulWidget {
  const _NoTlsCheck(this.st, {required this.single});
  final AppState st;
  final bool single;
  @override
  State<_NoTlsCheck> createState() => _NoTlsCheckState();
}

class _NoTlsCheckState extends State<_NoTlsCheck> {
  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final on = widget.single ? st.sNoTls : st.mNoTls;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Check(
          '仅 TCP 握手后直接发请求（不做 TLS 握手）',
          on,
          (v) => setState(() => widget.single ? st.sNoTls = v : st.mNoTls = v),
        ),
        if (on)
          const Padding(
            padding: EdgeInsets.only(top: 2, left: 8),
            child: Text(
              'https:// 的连接也不做 TLS 握手：TCP 握手完成后直接发送明文 HTTP 请求，端口和 Host 头不变。'
              '用于测试明文请求打到 TLS 端口、或被中间设备拦截时的表现。http:// 的连接不受影响。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
      ],
    );
  }
}

class MultiPage extends StatefulWidget {
  const MultiPage(this.st, {super.key});
  final AppState st;
  @override
  State<MultiPage> createState() => _MultiPageState();
}

class _MultiPageState extends State<MultiPage> {
  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    return SplitPage(
      st: st,
      logSrc: LogSrc.multi,
      // phone: keep most of the height for the connection list; desktop: show all options without scrolling
      maxFraction: MediaQuery.sizeOf(context).width >= 800 ? 0.48 : 0.32,
      top: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PageUrl(
              st,
              st.multi.url,
              (v) => st.multi.url = v.trim(),
              hint: '各连接默认用这个；也可在下方为每条连接单独设置',
            ),
            const SizedBox(height: 10),
            HttpOptsForm(st, st.multi),
            const SizedBox(height: 10),
            _MultiUrls(st),
            const SizedBox(height: 10),
            wrapRow([
              NumField(
                '连接总数',
                st.mCount,
                (v) => setState(() => st.mCount = v.toInt()),
                isInt: true,
                min: 1,
                max: 5000,
                width: 90,
              ),
              NumField(
                '并发上限',
                st.mConc,
                (v) => st.mConc = v.toInt(),
                isInt: true,
                min: 1,
                max: 1000,
                width: 90,
              ),
              NumField(
                '建连间隔(s)',
                st.mStagger,
                (v) => st.mStagger = v.toDouble(),
                max: 10,
                width: 100,
              ),
              Check(
                '日志显示每个连接的收发包',
                st.mVerbose,
                (v) => setState(() => st.mVerbose = v),
              ),
            ]),
            _NoTlsCheck(st, single: false),
            if (st.multi.keepAlive)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '勾选 keep-alive 后，请求完成的连接保持打开，并在列表里实时显示状态（持续/空闲，纯被动读取，不发探测包）。'
                  '「保持(s)」> 0 时到时关闭；为 0 时一直保持，直到点「停止」或服务器主动断开（会显示为「对端断开」及存活时长）。'
                  '保持中的空闲连接不占「并发上限」。',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
          ],
        ),
      ),
      actions: ValueListenableBuilder(
        valueListenable: st.status,
        builder: (c, _, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            wrapRow([
              FilledButton.icon(
                onPressed: st.multiBusy ? null : () => st.runMulti(context),
                icon: const Icon(Icons.play_arrow),
                label: const Text('开始'),
              ),
              OutlinedButton.icon(
                onPressed: st.multiBusy ? () => st.stop(LogSrc.multi) : null,
                icon: const Icon(Icons.stop),
                label: const Text('停止'),
              ),
              OutlinedButton.icon(
                onPressed: st.exportCsv,
                icon: const Icon(Icons.table_view),
                label: const Text('导出 CSV'),
              ),
            ]),
            if (st.lastSummary != null) ...[
              const SizedBox(height: 6),
              SelectableText(
                st.lastSummary!['text'] as String,
                style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
              ),
            ],
          ],
        ),
      ),
      middle: _Rows(st),
    );
  }
}

/// Multi mode URL choice: one URL for every connection, or a URL per connection.
class _MultiUrls extends StatefulWidget {
  const _MultiUrls(this.st);
  final AppState st;
  @override
  State<_MultiUrls> createState() => _MultiUrlsState();
}

class _MultiUrlsState extends State<_MultiUrls> {
  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final custom = [
      for (var i = 0; i < st.mCount; i++)
        if (st.mUrlAt(i).isNotEmpty) i,
    ].length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Check(
          '全部连接使用目标 URL',
          st.mSameUrl,
          (v) => setState(() => st.mSameUrl = v),
        ),
        if (!st.mSameUrl)
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: wrapRow([
              Text(
                '已单独设置 $custom / ${st.mCount} 条，其余用目标 URL',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.edit_note, size: 18),
                label: const Text('编辑每条连接的 URL'),
                onPressed: () async {
                  await Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => MultiUrlEditor(st)));
                  setState(() {});
                },
              ),
            ]),
          ),
      ],
    );
  }
}

/// Full-screen editor for the per-connection URLs (up to 5000 rows, built lazily).
class MultiUrlEditor extends StatefulWidget {
  const MultiUrlEditor(this.st, {super.key});
  final AppState st;
  @override
  State<MultiUrlEditor> createState() => _MultiUrlEditorState();
}

class _MultiUrlEditorState extends State<MultiUrlEditor> {
  int _gen = 0; // bump to rebuild every row after a bulk change

  void _bulk(String v) => setState(() {
    for (var i = 0; i < widget.st.mCount; i++) {
      widget.st.setMUrl(i, v);
    }
    _gen++;
  });

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final target = st.multi.url.trim();
    return Scaffold(
      appBar: AppBar(title: Text('每条连接的 URL（${st.mCount} 条）')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              '留空的连接使用目标 URL${target.isEmpty ? '（目标 URL 未填写）' : '：$target'}。点输入框右侧箭头可从 URL 历史选择，也可直接输入。',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: wrapRow([
              TextButton.icon(
                icon: const Icon(Icons.clear_all, size: 18),
                label: const Text('全部清空(用目标 URL)'),
                onPressed: () => _bulk(''),
              ),
              TextButton.icon(
                icon: const Icon(Icons.vertical_align_bottom, size: 18),
                label: const Text('用 #1 的 URL 填充全部'),
                onPressed: st.mUrlAt(0).isEmpty
                    ? null
                    : () => _bulk(st.mUrlAt(0)),
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: st.mCount,
              itemBuilder: (c, i) => Padding(
                key: ValueKey('murl-$_gen-$i'),
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        '#${i + 1}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Expanded(
                      child: UrlCombo(st.mUrlAt(i), st.history, (v) {
                        final wasEmpty = st.mUrlAt(0).isEmpty;
                        st.setMUrl(i, v);
                        if (i == 0 && wasEmpty != st.mUrlAt(0).isEmpty) {
                          setState(() {});
                        }
                      }, hint: target.isEmpty ? '填写 URL' : '留空 = $target'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String fmtMs(double secs) {
  if (secs < 1) return '${(secs * 1000).toStringAsFixed(0)}ms';
  if (secs < 60) return '${secs.toStringAsFixed(1)}s';
  return '${(secs ~/ 60)}m${(secs % 60).toStringAsFixed(0)}s';
}

class _Rows extends StatelessWidget {
  const _Rows(this.st);
  final AppState st;
  static const _colors = {
    '完成': Colors.green,
    '失败': Colors.red,
    '保存失败': Colors.red,
    '已取消': Colors.blueGrey,
    '无响应': Colors.red,
    '部分': Colors.orange,
    '保持中': Colors.teal,
    '对端断开': Colors.deepOrange,
  };
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: st.rowsVersion,
    builder: (c, _, _) {
      final keys = st.rows.keys.toList()..sort();
      if (keys.isEmpty) {
        return const Center(
          child: Text('连接列表', style: TextStyle(color: Colors.black38)),
        );
      }
      return ListView.separated(
        itemCount: keys.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (c, i) {
          final r = st.rows[keys[i]]!;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '#${r.idx}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      r.status,
                      style: TextStyle(
                        color: _colors[r.status] ?? Colors.blueGrey,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '状态码 ${r.codes}  成功 ${r.ok}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const Spacer(),
                    Text(
                      'conn ${r.cid}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black45,
                      ),
                    ),
                  ],
                ),
                if (!st.mSameUrl || r.url != st.multi.url.trim())
                  Text(
                    r.url,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Colors.indigo,
                    ),
                  ),
                Text(
                  'DNS ${r.dns}  TCP ${r.tcp}  代理 ${r.proxy}  TTFB ${r.ttfb}  ↑${r.tx} ↓${r.rx}  ${r.speed}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                  ),
                ),
                if (r.status == '保持中' ||
                    r.status == '已建立' ||
                    r.status == '接收中' ||
                    r.status == '对端断开')
                  Text(
                    r.status == '对端断开'
                        ? '存活 ${fmtMs(r.uptime)} 后被服务器关闭（最后空闲 ${fmtMs(r.idle)}）'
                        : '持续 ${fmtMs(r.uptime)}   空闲 ${fmtMs(r.idle)}   (被动读取，未发包)',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.blueGrey,
                    ),
                  ),
                if (r.error.isNotEmpty)
                  Text(
                    r.error,
                    style: const TextStyle(fontSize: 11.5, color: Colors.red),
                  ),
              ],
            ),
          );
        },
      );
    },
  );
}
