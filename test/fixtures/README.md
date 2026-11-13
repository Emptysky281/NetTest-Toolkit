# Local TLS test fixture

localhost-cert.pem and localhost-key.pem are a self-signed, test-only certificate/key pair. The private key is intentionally public and must never be used in production. SANs: localhost, 127.0.0.1, ::1. Validity: 2020-01-01 through 2040-01-01. Tests do not install this certificate into the system trust store.
