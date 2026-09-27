# Test-only TLS material

Used by the loopback HTTP/2 tests (`test/io/h2`, via `test/helpers/certs.dart`).
Never use these outside tests.

- `ca.pem`: a throwaway test CA. Its private key was deleted after signing,
  so nothing new can be issued from it.
- `localhost.pem` / `localhost.key`: a server certificate signed by the CA,
  SAN `localhost` and `127.0.0.1`, EC P-256.
- `untrusted.pem` / `untrusted.key`: a self-signed `localhost` certificate
  that no test trusts, for the rejection tests.

All three expire on 2028-12-30. Run `./generate.sh` to replace them before
then. They are valid for 825 days because macOS rejects TLS server
certificates valid for longer, even when the CA is trusted. On a Mac, a
longer-lived certificate fails every HTTP/2 test with
`CERTIFICATE_VERIFY_FAILED`.
