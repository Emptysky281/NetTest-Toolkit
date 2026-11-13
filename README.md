# NetTest

面向 **Windows / Android** 的 Flutter 网络测试客户端，支持 TCP/TLS 分阶段、HTTP 请求、代理诊断、多连接测试，以及 Windows 自定义进程名多开。

> 仅对获得授权的网络和服务执行测试。默认允许不受信任的证书，适合诊断；需要严格验证时请开启「强制校验证书」。

## 下载与安装

到本仓库的 [Releases](https://github.com/Emptysky281/NetTest/releases) 下载发布附件。

- **Windows x64**：下载 `NetTest-windows-x64-20261113.zip`，完整解压后运行 `nettest.exe`。不需要安装 Python；**不要只复制 EXE**，同目录 DLL 和 `data` 文件夹也必须保留。
- **Android**：源码支持构建 APK；当前 Release 只提供 Windows 新版，未将此前的测试签名 APK 混入此次发布。
- 私有仓库及其附件需要具有仓库访问权限的 GitHub 账号登录后下载。

## 主要功能

| 功能 | 说明 |
|---|---|
| 单连接 / 多连接 | keep-alive、多次请求、并发上限、间隔、保持、仅建 TCP、分段发送 |
| TCP/TLS 分阶段 | 手动推进 TCP、ClientHello、TLS 握手、HTTP 请求行/头/空行 |
| 代理 | 直连、SOCKS5、HTTP CONNECT、系统代理 |
| 诊断数据 | DNS/TCP/TLS/代理/TTFB 耗时、接收进度、连接存活状态、CSV 和日志导出 |
| 下载与日志 | 响应流式保存、中断文件标记、分页日志、HEX/载荷显示、稳定的尾部跟随 |
| 各页独立 | 每页设置自己的目标 URL，单连接和多连接可同时运行 |
| Windows 多开 | 用 `nettest_A.exe`、`nettest_B.exe` 等真实进程名启动独立实例 |

### 自定义进程名多开

1. 点击 PC 版右上角 **「多开」**。
2. 填写名称，例如 `nettest_A` 或 `nettest_B.exe`。
3. 选择是否复制当前设置与历史，点击 **「启动新实例」**。
4. 在任务管理器 **「详细信息」** 页查看对应 EXE 名称；「进程」页可能仍显示 NetTest 产品描述。

新实例使用独立配置、URL 历史、内存日志和下载目录。关闭一个窗口不会退出其他实例。为避免端口绑定冲突，新实例默认关闭固定端口段；需要抓包时请自行分配不重叠的范围。已创建的运行副本不会自动更新，升级主程序后请重新创建需要升级的实例。

## 源码目录

```text
lib/core/          网络核心、代理、HTTP、TLS、Windows 多开
lib/ui/            页面、状态与日志组件
lib/testing/       测试套件和模拟服务器
android/           Android 工程与 SSLEngine 桥接
windows/           Windows runner、OpenSSL 运行库与许可证
test/              核心、界面、滚动和多开回归测试
integration_test/  设备集成测试
tool/              检查、构建打包与 Android 辅助脚本
docs/              使用指南、开发说明和发布说明
```

`build/`、`dist/`、IDE/依赖缓存、本机路径、实际用户设置和签名密钥不进入 Git；Windows ZIP 作为 Release 附件发布。保留的测试证书/私钥仅用于本地测试，说明见 [test/fixtures](test/fixtures/README.md)。

## 开发与测试

已在 Flutter **3.47.7** / Dart **3.13.5** 下验证。Windows 构建需要 Visual Studio C++ 桌面工具；Android 需要相应 SDK/JDK。

```powershell
flutter pub get
.\tool\check.ps1
flutter build windows --release
.\tool\package-windows.ps1 -SkipBuild
```

默认检查排除依赖公网服务的 `core_test.dart`；需要完整外网测试时使用：

```powershell
.\tool\check.ps1 -IncludeExternalNetworkTests
```

详细命令、目录和构建要求见 [开发指南](docs/development.md)。

## 文档与边界

- [使用指南](docs/usage.md)
- [开发与发布](docs/development.md)
- [本版发布说明](docs/releases/2026-11-13.md)
- [变更记录](CHANGELOG.md)
- [第三方说明](THIRD_PARTY_NOTICES.md)

本仓库目前为私有项目，未另外授予开源许可；随附第三方组件遵循各自许可证。代理账号、URL 或自定义载荷可能包含敏感信息，程序会将相关设置和历史保存到本地，请勿将实际用户数据提交到仓库。
