# Contributing

Small, focused improvements are welcome.

1. Describe the behavior or problem before proposing a broad rewrite.
2. Keep changes limited to that behavior; preserve the native SwiftUI/AppKit architecture.
3. Use value fixtures and fake backends for tests. Never write live audio, network, power or existing preferences from a test.
4. Run the relevant tests and build. For UI changes, include a real screenshot of the changed area in Light and Dark.
5. Explain what changed, how it was verified and any remaining limits in the pull request.

No third-party runtime package is currently required. Discuss dependency additions before introducing them. Keep unknown readings unknown and protect device identity checks before system writes.

Do not attach unredacted diagnostic dumps, private IP/device identifiers, signing assets or credentials. Contributions are submitted under this project's MIT license. By contributing, you confirm you have the right to share the contribution.
