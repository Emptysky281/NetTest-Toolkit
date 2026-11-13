// Reusable form widgets and the live log view.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';

class NumField extends StatefulWidget {
  const NumField(
    this.label,
    this.value,
    this.onChanged, {
    super.key,
    this.isInt = false,
    this.min = 0,
    this.max = 1e9,
    this.width = 96,
  });
  final String label;
  final num value;
  final ValueChanged<num> onChanged;
  final bool isInt;
  final num min, max;
  final double width;
  @override
  State<NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<NumField> {
  late final TextEditingController c = TextEditingController(
    text: _fmt(widget.value),
  );
  String _fmt(num v) => widget.isInt
      ? v.toInt().toString()
      : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    child: TextField(
      controller: c,
      keyboardType: TextInputType.numberWithOptions(decimal: !widget.isInt),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
          RegExp(widget.isInt ? r'[0-9]' : r'[0-9.]'),
        ),
      ],
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: (s) {
        final v = widget.isInt ? int.tryParse(s) : double.tryParse(s);
        if (v != null) widget.onChanged(v.clamp(widget.min, widget.max));
      },
    ),
  );
}

class TextIn extends StatefulWidget {
  const TextIn(
    this.label,
    this.value,
    this.onChanged, {
    super.key,
    this.width,
    this.lines = 1,
    this.mono = false,
    this.obscure = false,
    this.hint,
    this.keyboard,
  });
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final double? width;
  final int lines;
  final bool mono, obscure;
  final String? hint;
  final TextInputType? keyboard;
  @override
  State<TextIn> createState() => _TextInState();
}

class _TextInState extends State<TextIn> {
  late final TextEditingController c = TextEditingController(
    text: widget.value,
  );

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TextIn old) {
    super.didUpdateWidget(old);
    if (widget.value != c.text && widget.value != old.value) {
      c.text = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = TextField(
      controller: c,
      maxLines: widget.lines,
      minLines: 1,
      obscureText: widget.obscure,
      keyboardType:
          widget.keyboard ??
          (widget.lines > 1 ? TextInputType.multiline : TextInputType.text),
      autocorrect: false,
      enableSuggestions: false,
      style: widget.mono
          ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
          : null,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: widget.onChanged,
    );
    return widget.width == null ? f : SizedBox(width: widget.width, child: f);
  }
}

class Check extends StatelessWidget {
  const Check(this.label, this.value, this.onChanged, {super.key});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    borderRadius: BorderRadius.circular(6),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: value,
          onChanged: (v) => onChanged(v ?? false),
          visualDensity: VisualDensity.compact,
        ),
        Flexible(child: Text(label)),
        const SizedBox(width: 6),
      ],
    ),
  );
}

class Drop extends StatelessWidget {
  const Drop(
    this.label,
    this.value,
    this.items,
    this.onChanged, {
    super.key,
    this.width = 120,
  });
  final String label, value;
  final List<String> items;
  final ValueChanged<String> onChanged;
  final double width;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: DropdownButtonFormField<String>(
      initialValue: value,
      isDense: true,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final i in items) DropdownMenuItem(value: i, child: Text(i)),
      ],
      onChanged: (v) => onChanged(v ?? value),
    ),
  );
}

/// This page's own target URL: type it, or pick from the shared URL history. Shows the outbound mode too.
class PageUrl extends StatelessWidget {
  const PageUrl(
    this.st,
    this.value,
    this.onChanged, {
    super.key,
    this.label = '目标 URL',
    this.hint,
  });
  final AppState st;
  final String value;
  final ValueChanged<String> onChanged;
  final String label;
  final String? hint;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: st.status, // refreshes the history list after a run
    builder: (c, _, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UrlCombo(
          value,
          st.history,
          onChanged,
          label: label,
          hint: hint ?? 'http://host:port/path 或 https://...',
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: Text(
            '本页目标地址独立设置，不影响其他页面；右侧箭头可选共用 URL 历史。\n'
            '出站方式：${st.settings.proxy.mode}（可在「设置」页修改）',
            style: const TextStyle(fontSize: 11.5, color: Colors.black54),
          ),
        ),
      ],
    ),
  );
}

/// URL box: type freely, or open the list to pick from the URL history.
class UrlCombo extends StatefulWidget {
  const UrlCombo(
    this.value,
    this.history,
    this.onChanged, {
    super.key,
    this.label,
    this.hint,
  });
  final String value;
  final List<String> history;
  final ValueChanged<String> onChanged;
  final String? label, hint;
  @override
  State<UrlCombo> createState() => _UrlComboState();
}

class _UrlComboState extends State<UrlCombo> {
  late final TextEditingController c = TextEditingController(text: widget.value)
    ..addListener(_changed);
  String _last = '';

  void _changed() {
    if (c.text == _last) return;
    _last = c.text;
    widget.onChanged(c.text);
  }

  @override
  void initState() {
    super.initState();
    _last = widget.value;
  }

  @override
  void didUpdateWidget(UrlCombo old) {
    super.didUpdateWidget(old);
    if (widget.value != c.text && widget.value != old.value) {
      c.text = widget.value;
    }
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DropdownMenu<String>(
    controller: c,
    expandedInsets: EdgeInsets.zero,
    requestFocusOnTap: true,
    enableFilter: false,
    menuHeight: 320,
    label: widget.label == null ? null : Text(widget.label!),
    hintText: widget.hint,
    keyboardType: TextInputType.url,
    textStyle: const TextStyle(fontSize: 14),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      border: OutlineInputBorder(),
    ),
    dropdownMenuEntries: [
      for (final h in widget.history) DropdownMenuEntry(value: h, label: h),
    ],
    onSelected: (v) {
      if (v != null) c.text = v;
    },
  );
}

/// Custom payload box with the history built in: the history button inside the box puts the chosen
/// entry into this same box, so what is shown is exactly what will be sent.
class PayloadField extends StatefulWidget {
  const PayloadField(
    this.st,
    this.label,
    this.value,
    this.onChanged, {
    super.key,
    this.hint,
    this.lines = 2,
  });
  final AppState st;
  final String label, value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final int lines;
  @override
  State<PayloadField> createState() => _PayloadFieldState();
}

class _PayloadFieldState extends State<PayloadField> {
  late final TextEditingController c = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(PayloadField old) {
    super.didUpdateWidget(old);
    if (widget.value != c.text) c.text = widget.value;
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  void _set(String v) {
    c.value = TextEditingValue(
      text: v,
      selection: TextSelection.collapsed(offset: v.length),
    );
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: c,
    maxLines: widget.lines,
    minLines: 1,
    keyboardType: TextInputType.multiline,
    autocorrect: false,
    enableSuggestions: false,
    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    decoration: InputDecoration(
      labelText: widget.label,
      hintText: widget.hint,
      isDense: true,
      border: const OutlineInputBorder(),
      suffixIcon: ValueListenableBuilder(
        valueListenable: widget.st.status,
        builder: (ctx, _, _) {
          final h = widget.st.payloadHistory;
          return PopupMenuButton<int>(
            tooltip: h.isEmpty ? '载荷历史(空)：运行后自动记入' : '从载荷历史选择 (${h.length})',
            enabled: h.isEmpty == false,
            icon: const Icon(Icons.history),
            onSelected: (i) async {
              if (i >= 0) {
                _set(widget.st.payloadHistory[i]);
              } else if (await confirm(
                context,
                '清空载荷历史',
                '删除全部 ${widget.st.payloadHistory.length} 条历史载荷？输入框里的当前内容不受影响。',
              )) {
                widget.st.clearPayloadHistory();
              }
            },
            itemBuilder: (_) => [
              for (var i = 0; i < h.length; i++)
                PopupMenuItem(
                  value: i,
                  child: Text(
                    h[i].replaceAll('\n', ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: -1,
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 18),
                    SizedBox(width: 8),
                    Text('清空载荷历史'),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
    onChanged: widget.onChanged,
  );
}

Widget wrapRow(List<Widget> children) => Wrap(
  spacing: 8,
  runSpacing: 10,
  crossAxisAlignment: WrapCrossAlignment.center,
  children: children,
);

Widget section(String title, List<Widget> children) => Padding(
  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 13,
          color: Colors.black54,
        ),
      ),
      const SizedBox(height: 8),
      ...children,
    ],
  ),
);

/// Top area scrolls (max [maxFraction] of height); live log fills the rest.
class SplitPage extends StatelessWidget {
  const SplitPage({
    super.key,
    required this.top,
    required this.st,
    this.maxFraction = 0.55,
    this.middle,
    this.actions,
    this.logSrc,
  });
  final Widget top;

  /// The log area shows only this page's entries; the 日志 page shows all of them.
  final LogSrc? logSrc;
  final Widget? middle;

  /// Always-visible bar below the scrollable options.
  final Widget? actions;
  final AppState st;
  final double maxFraction;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (c, box) => Column(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: box.maxHeight * maxFraction),
          child: SingleChildScrollView(child: top),
        ),
        if (actions != null)
          Material(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: SizedBox(width: double.infinity, child: actions!),
            ),
          ),
        if (middle != null) Expanded(flex: 3, child: middle!),
        const Divider(height: 1),
        Expanded(flex: 2, child: LogView(st, src: logSrc)),
      ],
    ),
  );
}

const kindColors = {
  'tx': Color(0xFF4FC1FF),
  'rx': Color(0xFFB5CEA8),
  'err': Color(0xFFF48771),
  'state': Color(0xFFDCDCAA),
  'close': Color(0xFFDCDCAA),
  'http': Color(0xFFC586C0),
  'info': Color(0xFF9CDCFE),
  'done': Color(0xFFC586C0),
  'tls': Color(0xFFCE9178),
};

class LogView extends StatefulWidget {
  const LogView(this.st, {super.key, this.src});
  final AppState st;

  /// null = every entry (日志 page); otherwise only entries from that function page.
  final LogSrc? src;
  @override
  State<LogView> createState() => _LogViewState();
}

// The live tail is a real zero-offset boundary, not an estimated maxScrollExtent.
// Correct during layout so resizing/rebasing cannot paint an intermediate jump.
class _LogScrollController extends ScrollController {
  _LogScrollController(this.pinToTail) : super(keepScrollOffset: false);
  final bool Function() pinToTail;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _LogScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    pinToTail: pinToTail,
  );
}

class _LogScrollPosition extends ScrollPositionWithSingleContext {
  _LogScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.pinToTail,
  }) : super(initialPixels: 0, keepScrollOffset: false);
  final bool Function() pinToTail;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    if (pinToTail() && pixels != 0) {
      correctPixels(0);
      return false;
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

class _LogViewState extends State<LogView> {
  late final sc = _LogScrollController(() => _pinToTail);
  Key _tailKey = UniqueKey();
  LogItem? _anchor;
  bool _following = true, _userScrolling = false, _pinToTail = true;
  late bool _autoScroll = widget.st.autoscroll;

  @override
  void dispose() {
    sc.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(LogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.st != widget.st || oldWidget.src != widget.src) {
      _anchor = null;
      _following = true;
      _userScrolling = false;
      _autoScroll = widget.st.autoscroll;
    }
  }

  bool _onScroll(ScrollNotification notification) {
    // A payload's horizontal scrolling must not pause vertical tail-following.
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _userScrolling = true;
      _pinToTail = false;
    } else if (notification is ScrollUpdateNotification && _userScrolling) {
      _following = notification.metrics.extentAfter <= 40;
    } else if (notification is ScrollEndNotification) {
      _userScrolling = false;
      _following = notification.metrics.extentAfter <= 40;
      if (_following && widget.st.autoscroll) setState(() {});
    }
    return false;
  }

  Widget _logList(List<LogItem> source) {
    // Freeze each delegate's data until the next logVersion, including on cap
    // eviction. Keys and the split anchor preserve the history being browsed.
    final logs = List<LogItem>.of(source, growable: false);
    final enabled = widget.st.autoscroll;
    if (enabled && !_autoScroll) _following = true;
    _autoScroll = enabled;
    if (logs.isEmpty) {
      _anchor = null;
      _following = true;
      _userScrolling = false;
      _pinToTail = false;
      return Center(
        child: Text(
          widget.src == null ? '实时收发日志（全部）' : '实时收发日志（仅本页的连接，全部日志见「日志」页）',
          style: const TextStyle(color: Colors.white38),
        ),
      );
    }

    final previousAnchor = _anchor;
    _pinToTail = enabled && _following && !_userScrolling;
    if (_anchor == null || _pinToTail) _anchor = logs.last;
    final indices = {for (var i = 0; i < logs.length; i++) logs[i]: i};
    // If the user's entire anchor was evicted, clamp to the oldest surviving
    // content rather than silently returning to live output.
    if (!indices.containsKey(_anchor)) _anchor = logs.first;
    final split = indices[_anchor]! + 1;
    if (!identical(previousAnchor, _anchor)) {
      // A changed zero boundary is a new coordinate system. Do not let a
      // SliverList reuse stale layout offsets and counteract the tail correction.
      _tailKey = UniqueKey();
    }

    int? childIndex(Key key, bool before) {
      if (key is! ObjectKey) return null;
      final index = indices[key.value];
      if (index == null || (before ? index >= split : index < split)) {
        return null;
      }
      return before ? split - index - 1 : index - split;
    }

    Widget entry(int index) =>
        KeyedSubtree(key: ObjectKey(logs[index]), child: _row(logs[index]));
    return SelectionArea(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: CustomScrollView(
            controller: sc,
            primary: false,
            anchor: 1,
            center: _tailKey,
            semanticChildCount: logs.length,
            slivers: [
              // History grows upwards; zero stays at the bottom of the panel.
              SliverList(
                key: ObjectKey(_anchor),
                delegate: SliverChildBuilderDelegate(
                  (c, i) => entry(split - i - 1),
                  childCount: split,
                  findChildIndexCallback: (key) => childIndex(key, true),
                  semanticIndexCallback: (_, i) => split - i - 1,
                ),
              ),
              // While paused, keep the boundary fixed. New logs grow BELOW it,
              // leaving the visible history unmoved, even when old logs expire.
              SliverList(
                key: _tailKey,
                delegate: SliverChildBuilderDelegate(
                  (c, i) => entry(split + i),
                  childCount: logs.length - split,
                  findChildIndexCallback: (key) => childIndex(key, false),
                  semanticIndexOffset: split,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF1E1E1E),
    child: ValueListenableBuilder(
      valueListenable: widget.st.logVersion,
      builder: (c, _, _) => _logList(widget.st.logsFor(widget.src)),
    ),
  );

  Widget _row(LogItem l) {
    final st = widget.st;
    final pt = st.showPayload ? AppState.payloadText(l, st.showHex) : null;
    const mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 11.5,
      height: 1.3,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppState.head(l),
            style: mono.copyWith(color: kindColors[l.e.kind] ?? Colors.white70),
          ),
          if (pt != null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: const EdgeInsets.only(left: 18),
                child: Text(
                  pt,
                  style: mono.copyWith(color: const Color(0xFF8A8A8A)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
