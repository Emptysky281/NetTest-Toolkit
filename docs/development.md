# 开发与发布

## 工具链

- 已验证：Flutter 3.47.7、Dart 3.13.5（以 `pubspec.yaml` 的 SDK 约束为准）。
- Windows：Visual Studio 2022 或对应生成工具，启用「使用 C++ 的桌面开发」。
- Android：Android SDK、兼容的 JDK。发布签名由维护者自行配置；仓库不包含 keystore。

不要提交 `android/local.properties`；在自己的机器上运行 `flutter pub get` 并设置 SDK，Flutter 会生成本机配置。

## 检查

```powershell
flutter pub get
.\tool\check.ps1
# SDK 没有加入 PATH 时：
.\tool\check.ps1 -FlutterPath C:\dev\flutter\bin\flutter.bat
# 包含公网连接和 badssl 证书测试：
.\tool\check.ps1 -IncludeExternalNetworkTests
```

`check.ps1` 执行依赖解析、静态分析和回归测试，递归发现测试文件，默认排除整个 `test/external/` 目录。Windows 下自动设置项目内 OpenSSL 路径，并在结束后恢复原环境变量和工作目录。测试辅助代码统一放在 `test/support/`，不再位于应用源码 `lib/` 中；设备集成测试复用同一份辅助代码。详见 [测试说明](../test/README.md)。

当前验证环境的 Flutter 3.47.7 在中文项目路径下执行 `flutter analyze` 时出现 LSP 消息解析异常；同一 SDK 的 `dart analyze` 可以正常完成。遇到此问题可显式指定分析器，不必修改 SDK 或移动整个项目：

```powershell
.\tool\check.ps1 -FlutterPath C:\dev\flutter\bin\flutter.bat -DartPath C:\dev\flutter\bin\dart.bat
```

`-DartPath` 只替换静态分析入口（执行 `dart analyze --fatal-infos`），依赖解析和测试仍使用指定的 Flutter；未传入时继续使用 `flutter analyze --no-pub`。已执行过 `flutter pub get` 且依赖缓存完整时，可加 `-SkipPubGet`。

- `test/core/instance_test.dart`、`test/ui/instance_ui_test.dart`：自定义进程名、独立配置、启动错误、界面流程。
- `test/ui/log_scroll_test.dart`：Windows 平台模式的逐帧尾部跟随、长响应、阅读位置与日志淘汰。
- `test/core/download_stability_test.dart`、`test/core/stability_test.dart`：本地下载、取消、DNS、状态与证书回归。
- `test/state/prefs_test.dart`、`test/ui/log_pages_test.dart`、`test/ui/pages_independent_test.dart`、`test/ui/ui_stability_test.dart`：设置和实际界面。
- `test/external/core_test.dart`：还会连接公网服务器；网络阻断、服务器提前关闭等情况应单独分析，不应直接视为本地功能回归。
- `integration_test/app_test.dart`：需要设备或模拟器，使用 `flutter test integration_test/app_test.dart -d <设备ID>`。

2026-11-13 验证结果：77 个本地用例通过，核心套件用例内部 90 项检查通过；还验证了真实不同名称进程并行、独立退出及再次启动。内部检查数不与测试用例数混为一谈。

## Windows 构建和打包

```powershell
.\tool\package-windows.ps1
# 已完成当前源码的构建时：
.\tool\package-windows.ps1 -SkipBuild
```

打包脚本不会覆盖已有同名 ZIP。输出到 `dist/archive/windows/<发布日期>/`，包含全部 Flutter/DLL/data 运行文件、使用说明、变更记录和第三方许可证，另生成 SHA-256 校验文件。发布时将 ZIP 和校验文件作为 GitHub Release 附件，**不要把 dist/ 加入源码历史**。

本地交付目录已按平台、日期归档：`dist/latest/windows/` 为现有最新 Windows 包的完整解压副本，`dist/latest/packages/` 为对应 ZIP 和校验文件，`dist/latest/android/` 为现有最新 Android APK，原文件保存在 `dist/archive/`。Windows 当前精选版本为 2026-11-16，Android 为 2026-11-04；2026-11-16 同时是本次 Windows 构建和整理日期。`dist/README.md`、`inventory.json` 和根校验索引记录当前布局。打包脚本只生成不可覆盖的日期归档，不自动替换 `latest/`；更换最新副本时，应同步完整运行文件、包、版本信息和校验索引。

本版使用日期标签 `windows-2026.11.16`；日期标签不是修改应用内的 `0.1.0+1` 版本号。后续做安装包升级时应同时管理应用版本和发布标签。

## Android 构建

```powershell
flutter build apk --release --split-per-abi
```

当前工程的 release 配置仍使用测试签名，仅用于测试；正式分发前需自行设置签名。`tool/dev.ps1` 是可选的 Android 辅助脚本，包含安装/输入/截图动作；常规检查和 Windows 打包不会调用这些动作。

## 数据和多开目录

- 主程序设置：Windows 应用支持目录下的 `settings.json` / `url_history.json`。
- 每次新建多开实例：`instances/<实例ID>/bundle/` 保存运行副本，`profile/` 保存独立设置，`profile/downloads/` 保存下载。
- 同一个已创建 EXE 再次打开会复用同一 profile；需要完全隔离时应从「多开」创建新的副本。
- 测试和审核记录保留在本地，不随源码上传；`test/fixtures/` 是明确标注的专用测试材料，不是真实服务密钥。

## 仓库边界

源码只维护本项目；旧 Python 客户端和其他工具不在此仓库。旧安装包和本机缓存未删除，只是不纳入 Git。不要上传代理口令、实际 URL 历史、抓包文件、日志、用户下载内容或系统本机路径。
