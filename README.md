# NetTest Toolkit

NetTest 是一个 Windows / Android 网络测试客户端，使用 Flutter 开发。支持 TCP/TLS 分阶段操作、HTTP 请求、SOCKS5 和 HTTP CONNECT 代理，以及多连接测试。

[下载 Windows 版](https://github.com/Emptysky281/NetTest-Toolkit/releases/latest) · [使用说明](docs/usage.md) · [开发说明](docs/development.md)

## 下载

Windows x64：在 [Releases](https://github.com/Emptysky281/NetTest-Toolkit/releases/latest) 下载 `NetTest-windows-x64-20261116.zip`，解压后运行 `nettest.exe`。

请完整解压，EXE、DLL 和 `data` 目录不能分开。不需要安装 Python 或 Flutter SDK。附件里的 `.sha256` 和 `SHA256SUMS.txt` 可用于校验下载文件。

Android 目前需要自行编译，当前 Release 没有 APK。工程的 Release 配置仍使用测试签名，正式分发前需要更换。

## 功能

- 单连接、多连接测试：请求次数、并发数、间隔、keep-alive、连接保持，每条连接可设置不同 URL。
- 分阶段发送：TCP 建连、ClientHello、TLS 握手、HTTP 请求行、请求头、空行，也可发送自定义字节。
- 代理：直连、SOCKS5、HTTP CONNECT、系统代理；SOCKS5 可选择远端解析域名。
- 查看 DNS、TCP、TLS、代理和 TTFB 耗时，导出多连接结果为 CSV。
- 流式下载正文，中断文件标记为 `.incomplete`；日志支持 HEX、载荷显示和导出。
- Windows 下可用不同 EXE 名称多开，各实例的设置、历史和下载目录独立。

## 使用

1. 在「设置」里选择出站方式、超时和保存目录。
2. 在「单连接」里填 URL，点击「建立连接并请求」。页面下方会显示收发日志。
3. 需要并发测试时切换到「多连接」。各页的 URL 和运行状态独立，「停止」只停本页的任务。

分阶段测试使用「TCP/TLS 分阶段」页：

```text
① TCP 握手 → ② 发 ClientHello → 等服务器回包 → ③ 继续 TLS 握手
          → ④ 请求行 → ⑤ 请求头 → ⑥ 空行
```

HTTP 目标可以跳过②③。HTTPS 需要等握手完成后再发请求，③可能要点多次。①执行的是完整 TCP 三次握手，不能只发一个 SYN。

默认不校验证书。需要检查证书链、有效期和主机名时，请勾选「强制校验证书」。

### Windows 多开

点击右上角「多开」，输入 `nettest_A` 或 `nettest_B.exe`，再点「启动新实例」。这会创建实际的独立进程，进程名在任务管理器的「详细信息」页查看。顶部标题也可以选中复制。

新实例默认关闭固定端口段，避免端口冲突。创建过的运行副本不会自动升级，更新主程序后需要重新创建。

## 编译与测试

已验证环境：Flutter 3.47.7、Dart 3.13.5。Windows 需要 Visual Studio 的 C++ 桌面开发组件，Android 需要 SDK/JDK。

```powershell
git clone https://github.com/Emptysky281/NetTest-Toolkit.git
cd NetTest-Toolkit
flutter pub get
flutter run -d windows
```

```powershell
# 静态分析和本地测试，默认不跑公网测试
.\tool\check.ps1

# 包含公网测试
.\tool\check.ps1 -IncludeExternalNetworkTests

# 构建 Windows Release 并打包
.\tool\package-windows.ps1

# 按设备架构构建 Android APK
flutter build apk --release --split-per-abi
```

Windows 包输出到 `dist/archive/windows/<发布日期>/`，不会覆盖已有同名包。发布其他日期的版本时，传入 `-ReleaseDate yyyy-MM-dd` 并准备对应发布说明。SDK 路径、签名和设备测试见[开发说明](docs/development.md)。

## 目录

```text
lib/core/          网络连接、协议、下载和平台接口
lib/ui/            页面、状态和日志组件
windows/           Windows runner 和 OpenSSL
android/           Android 工程和 SSLEngine 桥接
test/              核心、状态、界面及公网测试
integration_test/  设备集成测试
tool/              检查和打包脚本
docs/              使用、开发和发布说明
```

更多说明：[项目架构](docs/architecture.md)、[测试说明](test/README.md)、[更新记录](CHANGELOG.md)、[文档索引](docs/README.md)。

## 注意事项

- 只测试有授权的目标。直连仍可能受系统 VPN/TUN 和路由影响，本程序不是 VPN 或抓包工具。
- 「不做 TLS 握手」会直接发送明文，即使 URL 是 `https://`，不要用它发送敏感内容。
- 代理密码、URL 和载荷历史保存在本机，日志也可能含有口令或 Token，分享前请脱敏。
- `test/fixtures/` 里的证书和私钥仅用于本地测试，不要用于实际服务。

本项目暂未添加项目许可证。第三方组件说明及许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
