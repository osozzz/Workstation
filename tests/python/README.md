# Python ecosystem validation

This suite validates the specialized read-only Python ecosystem provider introduced for Sprint 2 issue #30.

It covers:

- active `python` command resolution and normalized interpreter version;
- multiple interpreter installations from safe command probes, the Windows `py` launcher/install manager, and bounded PEP 514 registry registrations;
- modern `py list --format=json` runtime enumeration with legacy `py -0p` fallback;
- explicit protection against executing WindowsApps/Python Install Manager aliases that could trigger automatic runtime installation;
- pip detection through both the direct command and the active interpreter's `-m pip --version` probe;
- independent pipx and uv detection;
- conservative pyenv-win detection through `PYENV_ROOT`, `pyenv --version`, and `pyenv versions --bare`;
- command collisions, launcher-only state, missing pip, and partial configurations;
- migration of Python-specific ownership out of the transitional command inventory;
- source-level guards against package installation, environment creation, runtime installation, shim switching, and premature latest-version intelligence.

All committed fixtures are synthetic. They must not contain real workstation paths, usernames, credentials, tokens, machine names, or generated audit reports.

The provider intentionally does not walk arbitrary user directories or project virtual environments. Project-local Python/venv discovery belongs to the later project discovery milestone.

The workstation policy uses latest-stable for the global Python runtime and package tools while allowing projects to pin locally compatible versions. Actual latest-version lookup and upgrade recommendations remain in the later version-intelligence milestone.
