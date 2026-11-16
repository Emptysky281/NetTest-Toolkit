import 'package:flutter/material.dart';

import 'ui/app_state.dart';
import 'ui/instance_dialog.dart';
import 'ui/run_pages.dart';
import 'ui/settings_page.dart';
import 'ui/step_log_pages.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load the last-used settings first so every page opens with them.
  runApp(NetTestApp(await AppState.create()));
}

class NetTestApp extends StatelessWidget {
  const NetTestApp(this.st, {super.key});
  final AppState st;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: st.desktopInstance.isolated
        ? 'NetTest · ${st.desktopInstance.label}'
        : 'NetTest',
    debugShowCheckedModeBanner: false,
    scaffoldMessengerKey: st.messenger,
    theme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      visualDensity: VisualDensity.compact,
    ),
    home: Home(st),
  );
}

class Home extends StatefulWidget {
  const Home(this.st, {super.key});
  final AppState st;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 1;
  static const titles = ['设置', '单连接', '多连接', 'TCP/TLS 分阶段', '日志'];

  static const _dest = [
    (Icons.settings, '设置'),
    (Icons.call_made, '单连接'),
    (Icons.hub, '多连接'),
    (Icons.stairs, '分阶段'),
    (Icons.article, '日志'),
  ];

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final pages = IndexedStack(
      index: tab,
      children: [
        SettingsPage(st),
        SinglePage(st),
        MultiPage(st),
        StepPage(st),
        LogPage(st),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        // Wide window (Windows desktop): side rail; narrow (phone): bottom bar.
        final wide = box.maxWidth >= 800;
        return Scaffold(
          appBar: AppBar(
            title: Tooltip(
              message: '可选中复制 · 进程：${st.desktopInstance.label}',
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  st.desktopInstance.isolated
                      ? 'NetTest · ${st.desktopInstance.label} · ${titles[tab]}'
                      : 'NetTest · ${titles[tab]}',
                  maxLines: 1,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    // Cascadia Code is a readable programming font with softer
                    // curves; the fallbacks keep CJK page names legible.
                    fontFamily: 'Cascadia Code',
                    fontFamilyFallback: const [
                      'Cascadia Mono',
                      'Consolas',
                      'Microsoft YaHei UI',
                    ],
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.15,
                  ),
                ),
              ),
            ),
            actions: [
              NamedInstanceButton(st),
              ValueListenableBuilder(
                valueListenable: st.status,
                builder: (c, _, _) => st.busy
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          body: SafeArea(
            child: wide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: tab,
                        onDestinationSelected: (i) => setState(() => tab = i),
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          for (final (icon, label) in _dest)
                            NavigationRailDestination(
                              icon: Icon(icon),
                              label: Text(label),
                            ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: pages),
                    ],
                  )
                : pages,
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: tab,
                  onDestinationSelected: (i) => setState(() => tab = i),
                  destinations: [
                    for (final (icon, label) in _dest)
                      NavigationDestination(icon: Icon(icon), label: label),
                  ],
                ),
        );
      },
    );
  }
}
