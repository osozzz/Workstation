# JVM / Mobile precedence fixtures

This suite validates Sprint 3 issue #50 without mutating the runner.

It exercises derived cross-provider intelligence for:

- `JAVA_HOME` versus active `java` / `javac` PATH precedence;
- `FLUTTER_ROOT` versus active `flutter`;
- Flutter-bundled versus standalone Dart precedence;
- `ANDROID_HOME` versus `ANDROID_SDK_ROOT`;
- Android SDK roots versus active `adb` / `platform-tools`;
- approved `PUB_CACHE` evidence without requiring it on PATH;
- missing optional roots/tooling without false conflict findings.

The dedicated validator builds synthetic prior-provider results and confirms that
`jvm-mobile.precedence` owns zero components, performs no runtime discovery or
filesystem/environment probing, and never executes SDK/package mutation commands.
