# Test-only TLS material

Used by the loopback HTTP/2 tests (`test/io/h2`, via `test/helpers/certs.dart`).
Never use these outside tests.

- `ca.pem`: a throwaway test CA. Its private key was deleted after signing,
  so nothing new can be issued from it.
- `localhost.pem` / `localhost.key`: a server certificate signed by the CA,
  SAN `localhost` and `127.0.0.1`, EC P-256, valid for 100 years.
- `untrusted.pem` / `untrusted.key`: a self-signed `localhost` certificate
  that no test trusts, for the rejection tests.
