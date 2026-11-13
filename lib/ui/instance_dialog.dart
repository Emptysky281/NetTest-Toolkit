import 'package:flutter/material.dart';

import '../core/instance.dart';
import 'app_state.dart';

class NamedInstanceButton extends StatelessWidget {
  const NamedInstanceButton(this.state, {super.key});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (!state.supportsNamedInstances) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: state.status,
      builder: (context, _, _) => TextButton.icon(
        onPressed: state.launchingInstance
            ? null
            : () => showNamedInstanceDialog(context, state),
        icon: const Icon(Icons.open_in_new, size: 18),
        label: const Text('多开'),
      ),
    );
  }
}

Future<InstanceLaunchResult?> showNamedInstanceDialog(
  BuildContext context,
  AppState state,
) => showDialog<InstanceLaunchResult>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _NamedInstanceDialog(state),
);

class _NamedInstanceDialog extends StatefulWidget {
  const _NamedInstanceDialog(this.state);
  final AppState state;
  @override
  State<_NamedInstanceDialog> createState() => _NamedInstanceDialogState();
}

class _NamedInstanceDialogState extends State<_NamedInstanceDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.state.suggestedInstanceName,
  );
  bool _copySettings = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _launch() async {
    if (!_form.currentState!.validate() || widget.state.launchingInstance) {
      return;
    }
    setState(() => _error = null);
    try {
      final result = await widget.state.launchNamedInstance(
        _name.text,
        copySettings: _copySettings,
      );
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException ? e.message : '无法启动新实例：$e',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.state.status,
    builder: (context, _, _) {
      final busy = widget.state.launchingInstance;
      return PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: const Text('自定义进程名多开'),
          content: SizedBox(
            width: 490,
            child: SingleChildScrollView(
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '新实例会用独立名称的 EXE 启动，例如 nettest_A.exe、nettest_B.exe，不会修改当前运行的进程。',
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      key: const ValueKey('instance-process-name'),
                      controller: _name,
                      enabled: !busy,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: '新实例进程名',
                        hintText: 'nettest_A（可不填 .exe）',
                        helperText: '最多 64 字符，只填名称，不填路径',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        try {
                          instanceExecutableName(value ?? '');
                          return null;
                        } on FormatException catch (e) {
                          return e.message;
                        }
                      },
                      onFieldSubmitted: busy ? null : (_) => _launch(),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('复制当前设置与 URL 历史'),
                      value: _copySettings,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => _copySettings = v ?? true),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '各实例的设置、历史、日志与下载目录独立，关闭当前窗口不会关闭其他实例。'
                      '固定本地端口段默认关闭；如需抓包，请为不同实例设置不重叠的端口段。',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '任务管理器请查看“详细信息”页的 EXE 名称；“进程”页的产品描述仍可能显示 NetTest。'
                      '运行文件会保存在用户数据目录，可再次打开创建的 EXE。',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    if (busy) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 6),
                      const Text('正在准备独立运行文件…'),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      SelectableText(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: busy ? null : _launch,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('启动新实例'),
            ),
          ],
        ),
      );
    },
  );
}
