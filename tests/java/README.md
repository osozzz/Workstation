# Java/JVM toolchain validation

This suite validates the specialized read-only Java/JVM toolchain provider introduced for Sprint 2 issue #28.

It covers:

- active `java` and `javac` command resolution;
- multiple discoverable JDK/JRE installations;
- normalized Java version and major-version metadata;
- vendor/distribution, JDK/JRE kind, architecture, and installation-path evidence when locally supported;
- allowlisted `JAVA_HOME` inspection and mismatch detection;
- Apache Maven and Gradle presence/version/resolution;
- migration of Java-specific ownership out of the transitional command inventory;
- source-level guards against workstation mutation and premature latest-version intelligence.

All committed fixtures are synthetic. They must not contain real workstation paths, usernames, credentials, tokens, machine names, or generated audit reports.

The provider is intentionally read-only. It may inspect `java -XshowSettings:properties -version`, `javac -version`, Maven/Gradle version commands, `JAVA_HOME`, bounded JavaSoft registry locations, known Java installation roots, and JDK/JRE `release` metadata. It must not install, remove, switch, upgrade, repair, or modify Java, build tools, `JAVA_HOME`, PATH, or registry state.

Java uses the repository-wide `latest-stable` global policy. Actual latest-version lookup and upgrade recommendations remain outside this provider and belong to the later version-intelligence milestone.
