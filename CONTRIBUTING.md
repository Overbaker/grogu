# Contributing to Grogu

Contributions, bug reports, device/iOS-version compatibility reports, and PRs are very welcome!

## Ways to Contribute

- **iOS / iPadOS testing & compatibility**: Report iOS version, Tailscale RTT, and DDI/WDA behavior in [Issues](https://github.com/Overbaker/grogu/issues) or [Discussions](https://github.com/Overbaker/grogu/discussions).
- **Python gateway / worker / MCP (`src/`)**: Install editable dependencies (`pip install -e ".[worker]"`), keep PRs focused on a single concern, and include tests where practical.
- **Native Swift 6 app (`ios/`)**: Requires macOS + Xcode 16 + XcodeGen (`cd ios && make ipa UNSIGNED=1`).

## PR Guidelines

1. Keep pull requests focused and concise (open an issue/discussion first for architectural changes).
2. Never commit real Tailscale IPs, UDIDs, pairing `.plist` files, or API keys.
3. Root Python changes are licensed under **MIT**; `ios/` changes are licensed under **Apache-2.0** (respecting third-party attributions in `ios/NOTICE`).
