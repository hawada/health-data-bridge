# Contributing

Small, focused pull requests are welcome. Open an issue describing the observed behavior and expected result before proposing a substantial feature.

1. Build using the requirements in the README.
2. Use synthetic accounts, identifiers, dates and health values in fixtures.
3. Run the core suite and relevant service checks; for iOS behavior, run the applicable simulator tests.
4. Describe the change, tests performed and remaining limitations in your pull request.

Do not call real WHOOP services from automated tests, introduce credentials, add personal health evidence, or run synthetic HealthKit writes on a physical phone. Native integration writes are restricted to explicitly named isolated simulators.

Avoid changing persistent identifiers or migration behavior incidentally. Bundle identity, Keychain service, record ownership metadata and checkpoints affect existing installations. Handle such changes as explicit migrations with meaningful tests.

Keep WHOOP source parsing strict: ambiguous units, source states or sleep associations must not produce guessed health records. Respect retry deadlines and source limitations.

By contributing, you agree that your contributions are provided under the project's MIT license. Be respectful and do not request other users' private data.
