# Akkari CLI releases

Binary releases of the Akkari command-line interface for macOS (Apple Silicon and Intel) and Linux (x64 and arm64).
The source code is not published here. The CLI requires an Akkari account.

## Install

    curl -fsSL https://raw.githubusercontent.com/tekara-inc/akkari-cli-releases/main/install.sh | sh

The installer places versioned binaries under `~/.config/akkari/cli/` and links `~/.local/bin/akkari`.
Set `AKKARI_INSTALL_VERSION=<version>` to install a specific release and `AKKARI_NO_MODIFY_PATH=1` to leave shell files alone.

## Update

    akkari update

`akkari` checks for a newer release at most once a day and prints a one-line notice. Set `AKKARI_NO_UPDATE_CHECK=1` to disable the check.

## Verify a download

Each release carries `SHA256SUMS` and a `manifest.json` signed with minisign (`manifest.json.minisig`). The CLI verifies the manifest with its embedded public key on every update; you can verify by hand with `sha256sum -c SHA256SUMS`.

## Support

Contact your Akkari representative. Issues are not tracked in this repository.

© Tekara, Inc. All rights reserved. The binaries are provided under the Akkari terms of service.
