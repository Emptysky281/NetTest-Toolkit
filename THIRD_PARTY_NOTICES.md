# 第三方组件说明

## OpenSSL

Windows 手动 TLS 使用 `windows/openssl/libssl-3.dll` 和 `windows/openssl/libcrypto-3.dll`。随程序使用的运行库及其来源记录见同目录 `README.txt`；本项目不修改这些 DLL。

- OpenSSL 3 使用 Apache License 2.0。
- 完整许可证保存在 [windows/openssl/LICENSE.txt](windows/openssl/LICENSE.txt)，来自上游 openssl-3.0.21 标签的 LICENSE.txt。
- 更换运行库时，应同时更换匹配的 libssl/libcrypto 并检查许可证与归属说明。

## Flutter 和 Dart 依赖

依赖以 `pubspec.lock` 为准。Flutter Release 的 `data/flutter_assets/NOTICES.Z` 包含其生成的第三方通知；打包时保留完整 data 目录，不要省略该文件。此说明不替代各依赖的原有许可证。

## 测试证书

`test/fixtures/localhost-cert.pem` 与 `localhost-key.pem` 是公开可读的本地测试专用材料，不用于真实服务，也不安装到系统信任库；说明见 [test/fixtures/README.md](test/fixtures/README.md)。
