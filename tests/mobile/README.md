# Flutter, Dart, and Android toolchain validation

This suite validates the specialized read-only mobile toolchain provider introduced for Sprint 2 issue #29.

It covers:

- Flutter SDK version, channel, installation root, and command resolution;
- Flutter-bundled Dart versus standalone/external Dart resolution;
- allowlisted `FLUTTER_ROOT`, `PUB_CACHE`, `ANDROID_HOME`, and `ANDROID_SDK_ROOT`;
- Android SDK root discovery from environment, known Windows location, ADB, and `sdkmanager`;
- bounded local Android component metadata from `source.properties`;
- ADB and Android command-line tools presence/version/resolution;
- conflicting SDK roots, missing ADB, partial Flutter state, and inconsistent Dart relationships;
- migration of Flutter/Dart/ADB ownership out of the transitional command inventory;
- source-level guards against upgrades, channel switching, license acceptance, SDK mutation, and premature latest-version intelligence.

All committed fixtures are synthetic. They must not contain real workstation paths, usernames, credentials, tokens, machine names, or generated audit reports.

The provider intentionally avoids deep `flutter doctor` diagnostics and does not call remote package listings. Detection is based on version commands, command resolution, approved environment variables, bounded filesystem locations, and local Android SDK metadata.

The workstation policy keeps Flutter on the stable channel and uses latest-stable for Flutter and Android tooling. Actual latest-version lookup and upgrade recommendations remain in the later version-intelligence milestone.
