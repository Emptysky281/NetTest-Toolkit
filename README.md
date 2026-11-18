<div align="center">

# NetTest Toolkit

### 看清连接的每一步

面向 **Windows / Android** 的可视化网络诊断工具箱

TCP · TLS · HTTP/1.1 · SOCKS5 · HTTP CONNECT

**[下载 Windows 版](https://github.com/Emptysky281/NetTest-Toolkit/releases/latest)** · **[使用指南](docs/usage.md)** · **[开发指南](docs/development.md)** · **[变更记录](CHANGELOG.md)**

</div>

---

NetTest 不只是发送一次请求，还能把 **TCP 建连、ClientHello、TLS 握手、HTTP 发送和响应接收**分开观察，按需手动推进握手与发送，结合耗时、连接状态和收发数据辅助定位直连、代理或 VPN/TUN 环境下的问题。

这是一款 Flutter 客户端，网络测试在本机执行，**不需要部署本项目的后端服务**。仓库名为 `NetTest-Toolkit`，应用和发布包仍沿用 **NetTest** 名称。

> [!WARNING]
> 仅对获得授权的网络与服务执行测试。程序默认允许不受信任的证书；需要严格校验时，请在设置中开启「强制校验证书」。代理密码、URL 和自定义载荷历史会保存到本地，不要分享真实配置或敏感日志。

## 下载与安装

| 平台 | 交付情况 | 使用方式 |
|---|---|---|
| **Windows x64** | 当前发布：**2026-11-16** | 在 [Releases](https://github.com/Emptysky281/NetTest-Toolkit/releases/latest) 下载 `NetTest-windows-x64-20261116.zip`，完整解压后运行 `nettest.exe` |
| **Android** | 支持从源码构建；本次 Release 未提供 APK | 使用 Flutter 构建适配设备架构的 APK，见 [Android 构建说明](docs/development.md#android-构建) |

- **Windows 不需要安装 Python 或 Flutter SDK。** EXE、同目录 DLL 和 `data/` 必须一起保留，不要只复制 EXE。
- 仓库目前为私有项目，下载附件需要登录具有仓库访问权限的 GitHub 账号。
- Release 同时提供 `.sha256` 和 `SHA256SUMS.txt`；可在下载目录运行以下命令，将结果与校验文件比对：

```powershell
Get-FileHash .\NetTest-windows-x64-20261116.zip -Algorithm SHA256
```

> [!NOTE]
> Android 的 Release 构建配置目前仍使用测试签名，正式分发前需要配置自己的签名。Windows 发布日期标签与应用版本号分开管理：当前应用版本为 `0.1.0+1`。

## 快速开始一次测试

1. 打开 **「设置」**，选择出站方式：直连、SOCKS5、HTTP CONNECT 或系统代理；按需设置超时、证书校验和下载目录。
2. 进入 **「单连接」**，填写目标地址，例如 `https://example.com/`，点击 **「建立连接并请求」**。
3. 在页面下方查看日志，观察 DNS、TCP、TLS、TTFB 和 HTTP 响应；需要保存正文时，先确认「保存响应正文」已开启。

想比较多条连接，切换到 **「多连接」**；想拆开握手与发送过程，使用 **「TCP/TLS 分阶段」**。各页独立设置目标 URL，单连接与多连接可以同时运行。

## 能做什么

| 能力 | 你可以观察或控制的内容 |
|---|---|
| **单连接 / 多连接** | 每连接请求数、并发上限、建连/请求间隔、keep-alive、连接保持和逐连接 URL |
| **TCP/TLS 分阶段** | 单独建立 TCP，手动发送 ClientHello、继续 TLS 握手，再发送 HTTP 请求行、头和空行 |
| **代理诊断** | 直连、SOCKS5、HTTP CONNECT、系统代理；SOCKS5 可选择远端 DNS 解析 |
| **请求与载荷** | HTTP/1.1 请求、自定义请求头与正文、转义字节、分段发送和载荷历史 |
| **耗时与连接状态** | DNS/TCP/TLS/代理/TTFB 耗时、连接持续/空闲时间、多连接汇总与 CSV 导出 |
| **下载与日志** | 流式保存正文、中断文件标记、分页日志、HEX/载荷视图、自动跟随和日志导出 |
| **抓包辅助** | 固定本地端口段与过滤表达式，配合外部抓包工具定位流量 |
| **Windows 多开** | 以不同 EXE 名称启动独立进程，隔离设置、历史、内存日志和下载目录 |

### 分阶段测试怎么走

```text
① TCP 建连
   ├─ HTTP  ───────────────────────────────────────────────┐
   └─ HTTPS → ② 发 ClientHello → 等待回包 → ③ 继续 TLS 握手 ─┤
                                                          ↓
                         ④ 请求行 → ⑤ 请求头 → ⑥ 空行 → 接收响应
```

TCP 三次握手由操作系统完成，① 不是“只发一个 SYN”。HTTPS 的③可能需要多次推进，待 TLS 握手完成后再发送 HTTP。也可以一次发送完整请求，或手动发送自定义字节。

### Windows 自定义进程名多开

点击右上角 **「多开」** → 输入 `nettest_A` 或 `nettest_B.exe` → 选择是否复制当前设置与 URL 历史 → **「启动新实例」**。

- 这是实际的独立 EXE 进程，不是只修改窗口标题；请在任务管理器 **「详细信息」** 页查看进程名。
- 每次新建使用独立运行目录与 profile，关闭一个窗口不会退出其他实例。
- 新实例默认关闭固定本地端口段；需要抓包时，请为不同实例分配不重叠的范围。
- 运行副本不会自动升级。更新主程序后，请重新创建需要升级的实例。
- 顶部进程名、PID 和页面标题可选中复制，长标题可横向查看。

## 平台差异与边界

| 项目 | Windows | Android |
|---|---|---|
| 手动 TLS 引擎 | 随包附带的 OpenSSL 3，通过 Dart FFI 驱动 | 系统 `SSLEngine`，通过 MethodChannel 驱动 |
| 系统代理来源 | 当前用户 Internet Settings 的静态 HTTP / SOCKS 配置 | 系统 Wi-Fi HTTP 代理配置 |
| 默认下载位置 | 用户文档目录下的 `NetTest/downloads` | 应用外部文件目录下的 `downloads` |
| 导出 CSV / 日志 | 弹出「另存为」对话框 | 直接写入保存目录 |
| 自定义进程名多开 | 支持 | 不提供 |

- **直连不等于绕过 VPN/TUN。** 系统路由或透明代理仍可能影响流量；本工具本身不是 VPN，也不是抓包驱动。
- 系统代理模式不是完整的 PAC/WPAD 实现；需要明确的代理行为时，请手动填写 SOCKS5 或 HTTP CONNECT 配置。
- 连接状态通过已有收发事件被动更新，应用不会为状态刷新发送探测包；操作系统仍可能进行 TCP 重传。
- 「不做 TLS 握手」用于诊断明文请求打到 TLS 端口等异常场景，启用后即使填写 `https://` 也会发送明文，勿用于敏感请求。

## 从源码运行

已验证工具链：**Flutter 3.47.7 / Dart 3.13.5**。Windows 构建需要 Visual Studio C++ 桌面开发组件；Android 构建需要相应 SDK/JDK。依赖版本以 `pubspec.lock` 为准。

```powershell
git clone https://github.com/Emptysky281/NetTest-Toolkit.git
cd NetTest-Toolkit
flutter pub get
flutter run -d windows
```

### 检查与打包

```powershell
# 静态分析 + 本地回归；默认排除依赖公网的测试
.\tool\check.ps1

# 显式包含公网测试
.\tool\check.ps1 -IncludeExternalNetworkTests

# Windows Release 构建并打包
.\tool\package-windows.ps1

# Android 按 ABI 构建；正式分发前先配置签名
flutter build apk --release --split-per-abi
```

Windows 包输出到 `dist/archive/windows/<发布日期>/`，同名包不会被覆盖。后续发布日期应传入 `-ReleaseDate yyyy-MM-dd`，并准备对应发布说明。设备集成测试、公网测试和中文路径下的分析器注意事项，见 [开发指南](docs/development.md) 与 [测试说明](test/README.md)。

## 项目结构与文档

```text
lib/core/          TCP、TLS、HTTP、代理、下载与平台能力
lib/ui/            页面、状态管理、日志和多开交互
windows/           C++ runner、OpenSSL 运行库及许可证
android/           Android 工程与 Kotlin SSLEngine 桥接
test/              核心、状态、界面、公网测试及共用辅助代码
integration_test/  设备集成测试
tool/              检查、Windows 打包和 Android 辅助脚本
docs/              使用、架构、开发和历史发布说明
```

| 我想了解 | 文档 |
|---|---|
| 完整操作与参数说明 | [使用指南](docs/usage.md) |
| 网络执行链、原生桥接与数据目录 | [项目架构](docs/architecture.md) |
| SDK、测试、签名与发布流程 | [开发指南](docs/development.md) · [测试说明](test/README.md) |
| 本版变更和历史版本 | [2026-11-16 发布说明](docs/releases/2026-11-16.md) · [更新记录](CHANGELOG.md) |
| 其他文档与第三方材料 | [文档索引](docs/README.md) · [第三方说明](THIRD_PARTY_NOTICES.md) |

## 数据与许可

设置和 URL 历史保存在本机应用目录；代理密码、请求头和载荷可能包含敏感信息。反馈问题时，请先脱敏 URL、口令、Token 和日志载荷。构建缓存、安装包、实际 profile、下载内容与签名密钥不进入源码历史。

本仓库目前为私有项目，**未另行授予开源许可**。Flutter、Dart 依赖及 OpenSSL 遵循各自许可证；随包通知和 [OpenSSL 许可证](windows/openssl/LICENSE.txt) 均保留。[本地测试证书和私钥](test/fixtures/README.md) 是公开的测试专用材料，不用于真实服务。
