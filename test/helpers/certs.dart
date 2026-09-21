/// Test-only TLS material from `test/io/support/certs`, read relative to the
/// package root, which is where `dart test` runs.
library;

import 'dart:io';

const _certsDir = 'test/io/support/certs';

/// The test CA every trusted test certificate chains to; its key is deleted.
final List<int> testCaPem = _read('ca.pem');

/// A `localhost`/`127.0.0.1` server certificate signed by [testCaPem].
final List<int> localhostCertPem = _read('localhost.pem');

/// The private key of [localhostCertPem].
final List<int> localhostKeyPem = _read('localhost.key');

/// A self-signed `localhost` certificate no test context trusts.
final List<int> untrustedCertPem = _read('untrusted.pem');

/// The private key of [untrustedCertPem].
final List<int> untrustedKeyPem = _read('untrusted.key');

var _caTrusted = false;

/// Makes the process-wide default context trust [testCaPem], so the SDK's own
/// `Http2Client()` accepts the test servers. Per isolate; safe to call twice.
void trustTestCa() {
  if (_caTrusted) {
    return;
  }
  SecurityContext.defaultContext.setTrustedCertificatesBytes(testCaPem);
  _caTrusted = true;
}

/// A server context with the trusted `localhost` certificate (or the untrusted
/// one) offering [alpn]; server-side ALPN can only be set on a context.
SecurityContext serverContext({
  bool trusted = true,
  List<String> alpn = const ['h2'],
}) => SecurityContext()
  ..useCertificateChainBytes(trusted ? localhostCertPem : untrustedCertPem)
  ..usePrivateKeyBytes(trusted ? localhostKeyPem : untrustedKeyPem)
  ..setAlpnProtocols(alpn, true);

List<int> _read(String name) => File('$_certsDir/$name').readAsBytesSync();
