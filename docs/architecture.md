# 项目架构与目录职责

本文基于 2026-11-16 的源码梳理。重点是当前实现，不把规划中的功能当作已实现功能。

## 1. 项目定位

NetTest 是运行在 **Windows / Android** 上的 Flutter 网络诊断客户端，不是 Web 前端加独立后端的服务项目。

- Flutter 负责界面、状态、调度、HTTP 解析、下载和数据持久化。
- Dart `dart:io` 直接建立 TCP 连接和代理隧道，不依赖项目自带的远端 API。
- 自动 HTTPS 使用 Dart `RawSecureSocket`；手动 TLS 使用平台相关的 TLS 引擎。
- 仓库没有独立后端、数据库、Docker 部署或生产服务端；`test/support/mock_servers.dart` 中的服务只用于测试。

## 2. 目录分工

```text
nettest_flutter/
├── lib/
│   ├── main.dart                 应用初始化、桌面/移动导航和页面装配
│   ├── core/                     网络和平台能力
│   │   ├── session.dart          单连接生命周期、代理、TLS、收发、下载和取消
│   │   ├── runner.dart           HTTP 任务、并发调度、连接行和汇总统计
│   │   ├── http.dart             请求构造、增量响应解析、下载文件名
│   │   ├── proxy.dart            代理配置、SOCKS5 和 HTTP CONNECT 握手
│   │   ├── platform.dart         TLS 桥接、系统代理、应用和下载目录
│   │   ├── tls_openssl.dart      Windows OpenSSL FFI 与内存 BIO
│   │   ├── tls_view.dart         TLS 记录和握手消息的诊断视图
│   │   ├── instance.dart         Windows 命名进程与独立 profile
│   │   ├── win_dialog.dart       Windows 另存为对话框
│   │   └── util.dart             URL、时间、大小、转义和字节显示工具
│   └── ui/
│       ├── app_state.dart        页面参数、状态、设置、历史、日志和操作入口
│       ├── run_pages.dart        单连接、多连接、逐连接 URL 编辑和结果列表
│       ├── settings_page.dart    超时、代理、端口、证书和下载配置
│       ├── step_log_pages.dart   TCP/TLS/HTTP 分阶段及总日志页
│       ├── instance_dialog.dart  Windows 多开入口与输入校验
│       ├── widgets.dart          公共表单和日志滚动组件
│       └── theme.dart            预留视觉样式，当前 main.dart 尚未接入
├── android/                      Gradle 工程、Android 权限和 Kotlin TLS 桥接
├── windows/                      CMake、C++ runner、资源和 OpenSSL DLL/许可证
├── test/
│   ├── core/                     网络、下载、多开和业务稳定性测试
│   ├── state/                    设置恢复、迁移、历史和日志状态测试
│   ├── ui/                       页面交互、日志隔离、滚动和多开界面测试
│   ├── external/                 依赖公网的端到端核心套件
│   ├── support/                  宿主和设备测试共用的套件、模拟服务
│   └── fixtures/                 本地 TLS 测试专用证书和私钥
├── integration_test/             需要设备/模拟器的集成与黑洞诊断测试
├── tool/                         检查、Windows 打包和 Android 辅助脚本
└── docs/                         使用、开发、架构和历史发布文档
```

保留现有 `lib/core/`、`lib/ui/` 和平台目录，避免单纯整理文件引入业务重写。测试辅助代码不再位于 `lib/`；正式应用源码不依赖测试目录。

## 3. 启动和请求执行链

```text
main()
  → AppState.create()：加载偏好与 URL 历史，注册生命周期保存
  → NetTestApp / Home：五个页面放入 IndexedStack
  → 页面调用 AppState 的 runSingle / runMulti / stepConnect
  → MultiRunner（单连接也是 count=1 的运行器）或独立 TcpSession
  → DNS → TCP → 代理隧道（可选）→ TLS（可选）→ HTTP 收发
  → HttpResponseParser → 流式文件保存 + Ev 事件
  → AppState 批量刷新 → 页面日志、连接列表和汇总
```

### 连接和代理

- `TcpSession` 是一个 TCP 连接的所有者，负责建连、收发、超时和关闭。
- DNS 返回多个地址时，建连以 250ms 间隔尝试候选地址；失败后继续尝试，不让不可用地址一直挡住可用地址。
- 出站支持 `direct`、`socks5`、`http`、`system`；SOCKS5 可选择由代理解析目标域名。
- Windows 系统代理来自当前用户 Internet Settings 的静态配置，当前优先选择 `http`，其次 `socks`；并不是 PAC/WPAD 或完整 WinHTTP 代理实现。
- `direct` 仅表示应用未显式使用代理，仍可能受系统 VPN/TUN、路由和防火墙影响。
- 固定本地端口段用于抓包过滤，不可用端口会尝试切换；TCP 三次握手和重传由操作系统负责，不能把按钮理解为“仅发送一个 SYN”。

### TLS 平台边界

| 模式 | Windows | Android |
|---|---|---|
| 自动 HTTPS | Dart `RawSecureSocket` | Dart `RawSecureSocket` |
| 手动分阶段 TLS | `tls_openssl.dart`，OpenSSL 内存 BIO + FFI | `ManualTls.kt`，系统 `SSLEngine` |
| 手动 TLS 调用入口 | `platform.dart` 直接调用 OpenSSL 包装 | `nettest/native` MethodChannel |
| 手动严格校验的信任来源 | Windows ROOT / CA 证书库导入 OpenSSL | 系统 TLS 信任管理器 |

手动模式仍由 Dart 自己的 TCP 连接传输字节：② 发送 ClientHello 后缓存回包，③ 由用户继续推进握手。握手完成后再发送加密 HTTP。`tls_view.dart` 用于解释记录，不是抓包驱动或中间人代理。

### 并发、保持与取消

- 单连接、多连接和分阶段各自持有运行状态、目标 URL 和日志来源。
- 启动前先加锁；异步操作通过 epoch 和会话身份避免旧任务在取消后重新接管状态。
- 运行中的代理和任务参数取启动快照，后续修改设置不应改变已有连接。
- 并发上限约束建连和请求阶段；请求完成后的空闲保持不继续占用调度槽。
- 多连接启用 keep-alive 且保持时间为 0 时，请求完成后持续保持至停止或对端关闭；单连接的默认收尾规则不同，不能笼统视为无限保持。
- 连接状态每 500ms 被动刷新，等待提示不会主动发送探测包；操作系统仍可自行发送 TCP 重传等协议数据。
- 连接超时用于 DNS/TCP/代理/TLS 等阶段，不等同于整个测试的总时限；回包超时按连续无数据的空闲时间计算。0 表示不设应用侧对应时限，不保证系统或中间设备永不关闭连接。

## 4. 响应、下载和日志

### HTTP 与下载

- 自行构造和解析 HTTP/1.1；增量解析支持 Content-Length、chunked、连接关闭定界及 HEAD/204/304 无正文场景。
- 发送自定义载荷时按 UTF-8/转义生成字节，并自动填写正文的 Content-Length。
- 正文边收边写，不为下载在内存里聚合完整响应。
- 活跃同名下载先保留不同路径，临时文件附加连接/响应标识；完成后重命名，中断保存为 `.incomplete`。
- HTTP 接收成功与写盘失败分别统计；异步 IOSink 错误会进入保存失败处理。

### 日志

- 网络层通过 `Ev` 上报事件，UI 以 100ms 周期批量刷新。
- 总日志和每个功能页分别保留最多 5000 条；繁忙页面不会挤掉另一个页面的全部历史。
- 载荷在入队时复制并截断，默认每条保留 4096B，可配置范围为 16–65536B，不让日志间接持有原始大缓冲区。
- RX 明细有显示配额，之后用下载进度替代逐包输出。
- 日志视图使用固定底部锚点；主动上翻暂停跟随，回到底部或重新开启自动滚动后恢复。

## 5. 本地数据和 Windows 多开

- 主程序偏好保存在平台应用目录的 `settings.json`，URL 历史在 `url_history.json`；载荷历史属于偏好的一部分。
- 设置按变化保存，使用临时文件加重命名；URL 历史写入串行化，避免同时运行的页面相互覆盖。
- Windows 主实例默认下载到用户文档目录下的 `NetTest/downloads`；Android 默认使用应用外部文件目录下的 `downloads`。
- Windows 多开不是改窗口名：复制运行时 EXE、DLL 和 `data/`，创建真实不同文件名的独立进程。

```text
应用支持目录/
├── settings.json                 主实例偏好
├── url_history.json              主实例 URL 历史
└── instances/<唯一实例ID>/
    ├── bundle/
    │   ├── <自定义名称>.exe
    │   ├── *.dll / data/ ...
    │   └── nettest.instance.json  固定指向 ../profile
    └── profile/
        ├── settings.json
        ├── url_history.json
        └── downloads/
```

每次按钮新建都会获得独立目录；再次打开已创建的 EXE 复用其原 profile。新实例默认关闭固定端口段，避免复制同一端口范围。现有运行副本不会因更新主程序而自动升级。Windows C++ runner 从自身 EXE 所在目录加载 `data/`，不依赖调用方工作目录。

## 6. 仓库与产物边界

| 类型 | 位置 | 本次处理 |
|---|---|---|
| 受版本控制的源码和平台文件 | `lib/`、`android/`、`windows/` | 保留业务实现和平台标准结构 |
| 测试与公开测试材料 | `test/`、`integration_test/` | 分类、移动辅助代码并同步引用 |
| 生成缓存 | `.dart_tool/`、`build/`、`android/.gradle/`、`windows/flutter/ephemeral/` | 保留，不提交，不作为源码阅读对象 |
| IDE/本机配置 | `.idea/`、`*.iml`、`android/local.properties` | 保留，不提交 |
| 历史交付物 | `dist/` | 按平台、日期整理到 `archive/`；`latest/` 提供现有最新副本，原文件名和内容不变 |
| 真实用户数据 | 应用目录及用户选择的下载目录 | 不搬迁、不清理、不加入 Git |
| 必需的第三方二进制 | `windows/openssl/*.dll` | 保留；它们不是可随意删除的构建垃圾 |

`tool/package-windows.ps1` 从标准 Windows Release 目录创建完整 ZIP，附带使用说明、第三方材料和 SHA-256，输出到 `dist/archive/windows/<发布日期>/`，不覆盖同名发布包，也不自动替换 `latest/`。源码整理和本地交付物归档不等于已经重新构建或发布安装包。

## 7. 已知维护注意事项

以下是源码现状及后续工作的边界，不是本次顺手修改的功能：

1. 默认允许不受信任证书，且代理密码/URL/载荷历史会落盘；这是诊断工具的当前行为，不能按生产业务客户端的安全默认值理解。
2. Android release 目前仍使用 debug 签名配置，正式分发前需单独处理签名。
3. `app_state.dart` 同时承载参数模型、存储和执行入口，`session.dart` 同时管理传输与下载；若继续扩展，可另开变更拆分职责，本次不在文件整理中重写。
4. `theme.dart` 当前未被应用入口导入；保留它，不把未接入的样式误删为无用资源，也不在本次改变界面。
5. 公网套件依赖外部服务、真实证书站点和网络环境，与本地回归分开运行；设备测试也不由默认检查自动执行。

相关入口：[文档索引](README.md)、[开发指南](development.md)、[测试说明](../test/README.md)。
