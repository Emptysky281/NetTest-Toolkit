OpenSSL 3.0.21 runtime DLLs (libssl-3.dll, libcrypto-3.dll), copied from the official CPython 3.13
Windows installer. Used by lib/core/tls_openssl.dart for the step-by-step manual TLS on Windows.

OpenSSL 3.x is licensed under the Apache License 2.0: https://www.openssl.org/source/license.html
To update: replace both DLLs with a matching pair from a newer OpenSSL 3.x build (x64).
