import 'dart:io';

/// The package root, which every subprocess runs in.
final String packageRoot = Directory.current.path;

/// The parent environment without any `TYPESAFE_*` variable, so a subprocess
/// sees only the ones a test sets.
Map<String, String> scrubbedEnvironment([
  Map<String, String> extra = const {},
]) => {
  for (final MapEntry(:key, :value) in Platform.environment.entries)
    if (!key.startsWith('TYPESAFE_')) key: value,
  ...extra,
};

/// Arguments that run `test/process/fixtures/<name>.dart` on this VM with
/// [defines] as `-D` flags, bypassing pub.
List<String> fixtureArguments(
  String name, {
  Map<String, String> defines = const {},
  List<String> args = const [],
}) => [
  '--packages=$packageRoot/.dart_tool/package_config.json',
  for (final MapEntry(:key, :value) in defines.entries) '-D$key=$value',
  '$packageRoot/test/process/fixtures/$name.dart',
  ...args,
];

/// Runs fixture [name] to completion under a scrubbed environment plus [env].
Future<ProcessResult> runFixture(
  String name, {
  Map<String, String> env = const {},
  Map<String, String> defines = const {},
  List<String> args = const [],
}) => Process.run(
  Platform.resolvedExecutable,
  fixtureArguments(name, defines: defines, args: args),
  environment: scrubbedEnvironment(env),
  includeParentEnvironment: false,
  workingDirectory: packageRoot,
);

/// Starts fixture [name] under a scrubbed environment plus [env].
Future<Process> startFixture(
  String name, {
  Map<String, String> env = const {},
  List<String> args = const [],
}) => Process.start(
  Platform.resolvedExecutable,
  fixtureArguments(name, args: args),
  environment: scrubbedEnvironment(env),
  includeParentEnvironment: false,
  workingDirectory: packageRoot,
);
