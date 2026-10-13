/// mozhi_cli: translate text from the terminal with self-hosted Mozhi
/// instances and AI providers.
///
/// ```sh
/// dart pub global activate --source path packages/mozhi_cli
/// mozhi --help
/// ```
library;

export 'src/cli_context.dart' show ConfigStoreFactory, RepositoryFactory;
export 'src/command_runner.dart' show MozhiCliCommandRunner;
export 'src/console.dart' show Console;
