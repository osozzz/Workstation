# Flutter and Java version intelligence validation

This suite validates issue #82 with deterministic synthetic release metadata.

It covers Flutter stable-channel comparison, non-stable channel separation, Java same-major and distribution-aware comparison, higher-major isolation, multi-vendor evidence, architecture/package context, explicit source timestamps, and offline degradation.

The validation is read-only and does not require live access to Flutter release storage or the Foojay Disco API.
