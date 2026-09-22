# Non-JavaScript project detection validation

This suite validates issue #66 and the `projects.non-javascript` provider.

It creates a temporary bounded project tree, runs `projects.local`, and feeds only that discovery evidence into the classifier.

Coverage includes Flutter/Dart, Python, Rust, Go, .NET, Maven, Gradle, mixed-ecosystem roots, explicit runtime/toolchain constraints, and an intentionally invalid canonical config that must remain partial rather than disappearing.

The provider performs file-only inspection and does not build, restore, resolve dependencies, create environments, install packages, or execute project-defined code.
