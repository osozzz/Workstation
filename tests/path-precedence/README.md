# Command-to-PATH precedence validation

This suite validates Sprint 3 issue #48 without changing PATH or executing synthetic commands.

It proves:

- executable and external-script resolutions can map to normalized Process PATH entries;
- active and shadowed command precedence is preserved;
- distinct PATH origins produce an explicit precedence conflict;
- aliases and other non-PATH command types are never assigned PATH positions;
- path-based resolutions outside Process PATH remain explicitly unmapped;
- equivalent normalized PATH entries retain all candidate positions while the first effective position is identified.

The committed cases use only synthetic Windows paths.
