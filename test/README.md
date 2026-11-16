# 测试目录说明

## 分类

| 目录 | 测试文件/用途 | 环境要求 |
|---|---|---|
| `core/` | `download_stability_test.dart`：并发下载、异步写盘、截断响应和本地 TLS | 本地回环网络；手动 TLS 需平台引擎 |
| `core/` | `instance_test.dart`：进程名、运行文件复制、profile 隔离与失败清理 | Windows；进程启动使用测试替身 |
| `core/` | `stability_test.dart`：取消、DNS 候选、并发、非法地址和状态稳定性 | 本地回环网络和临时目录 |
| `state/` | `prefs_test.dart`：设置持久化、兼容迁移、历史、日志和代理字符串解析 | 宿主 Flutter 测试环境 |
| `ui/` | `instance_ui_test.dart`、`log_pages_test.dart`、`log_scroll_test.dart`、`pages_independent_test.dart`、`ui_stability_test.dart` | Flutter widget 测试，不要求实际弹出应用窗口 |
| `external/` | `core_test.dart`：运行包含公网目标、证书站点和较长等待的完整核心套件 | 可达的公网环境、相关平台 TLS 引擎 |
| `support/` | `mock_servers.dart`、`suite.dart`：共用 HTTP/代理模拟服务和检查套件 | 被宿主测试与设备集成测试引用，本身不是独立测试入口 |
| `fixtures/` | 本地自签名 TLS 证书及公开测试私钥 | 仅限测试，不导入系统信任库 |

`core/stability_test.dart` 也覆盖 AppState 与网络层之间的交互，并非只有纯协议单元测试。默认本地回归包含 9 个测试文件；其中 Windows 多开场景不代表 Android 功能验证。

## 运行本地回归（推荐）

从项目根目录执行：

```powershell
.\tool\check.ps1
# SDK 不在 PATH 时：
.\tool\check.ps1 -FlutterPath C:\dev\flutter\bin\flutter.bat
```

检查脚本递归发现 `test/` 下的 `*_test.dart`，默认排除整个 `external/` 目录，不依赖测试文件一定放在顶层。Windows 自动设置项目内 OpenSSL 路径并在退出时恢复；因此建议使用脚本运行完整本地检查。

当前 Flutter 分析入口若在中文路径下报 LSP 消息解析异常，可使用同一 SDK 的 Dart 分析器：

```powershell
.\tool\check.ps1 -FlutterPath C:\dev\flutter\bin\flutter.bat -DartPath C:\dev\flutter\bin\dart.bat
```

仅运行某类测试或单个回归：

```powershell
# Windows 手动 TLS：只对当前 PowerShell 会话设置测试用 DLL 查找路径。
$env:NETTEST_OPENSSL_DIR = Join-Path (Get-Location) 'windows\openssl'
flutter test test/core test/state test/ui
flutter test test/ui/log_scroll_test.dart
flutter test test/core/instance_test.dart
```

本地测试会启动回环监听、创建临时目录并访问文件系统，并不等于禁止一切 I/O。手动 TLS 引擎不可用时，对应用例可能被跳过，应检查实际测试输出。

## 公网测试：显式运行

```powershell
.\tool\check.ps1 -IncludeExternalNetworkTests
# 只运行公网套件：
flutter test test/external/core_test.dart
```

公网套件执行 `Suite.all()`，既包含本地检查，也会连接代码中配置的外部服务器、证书站点及测试目标。网络阻断、限速、对端提前断开或证书站点变化都可能影响结果；不要将其与默认本地回归混为一谈。**直接执行 `flutter test` 或 `flutter test test` 也会包含 `external/`，并不是离线模式。**

## 设备测试：单独运行

设备入口仍位于项目根目录的 `integration_test/`：

```powershell
flutter devices
flutter test integration_test/app_test.dart -d <设备ID>
# 黑洞/半关闭诊断，耗时可能较长：
flutter test integration_test/bh_test.dart -d <设备ID>
```

`app_test.dart` 通过相对路径引用 `test/support/suite.dart`，并在设备上启用手动 TLS 检查；它还会访问公网。`bh_test.dart` 用于观察黑洞连接的拆除行为，不属于默认快速回归。

`Suite.results` 中的检查项数与 Flutter 测试用例数不同，例如一个 Flutter 用例可执行多项内部检查；报告时分别列出，不相加。

## 2026-11-16 路径整理对照

| 原路径 | 新路径 |
|---|---|
| `lib/testing/mock_servers.dart` | `test/support/mock_servers.dart` |
| `lib/testing/suite.dart` | `test/support/suite.dart` |
| `test/core_test.dart` | `test/external/core_test.dart` |
| `test/download_stability_test.dart` | `test/core/download_stability_test.dart` |
| `test/instance_test.dart` | `test/core/instance_test.dart` |
| `test/stability_test.dart` | `test/core/stability_test.dart` |
| `test/prefs_test.dart` | `test/state/prefs_test.dart` |
| `test/instance_ui_test.dart` | `test/ui/instance_ui_test.dart` |
| `test/log_pages_test.dart` | `test/ui/log_pages_test.dart` |
| `test/log_scroll_test.dart` | `test/ui/log_scroll_test.dart` |
| `test/pages_independent_test.dart` | `test/ui/pages_independent_test.dart` |
| `test/ui_stability_test.dart` | `test/ui/ui_stability_test.dart` |

新增测试遵循上述分类，独立入口以 `_test.dart` 结尾；共用代码放在 `support/`，不要使用该后缀。需要公网的入口放在 `external/`，设备测试继续放在 `integration_test/`。
