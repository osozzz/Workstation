# Local project discovery validation

This suite validates issue #64 and the `projects.local` provider.

The validator creates only synthetic temporary directories under the runner temp directory. It verifies:

- multiple configured development roots;
- equivalent/duplicate roots;
- missing roots;
- rejection of filesystem-root traversal;
- an empty configured root;
- nested Git repositories;
- generic project-candidate markers;
- maximum discovery depth;
- a synthetic project outside configured roots that must never be discovered;
- zero component ownership;
- read-only/bounded safety evidence;
- neutral behavior when no local development roots are configured;
- invalid local configuration behavior without filesystem traversal.

No real workstation paths or generated project inventories are committed.
