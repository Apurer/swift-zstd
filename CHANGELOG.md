# Changelog

All notable changes to this project will be documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
- Add Swift-DocC catalog with getting started, streaming vs one-shot, safety, and dictionary usage guides.
- Introduce formatting config (`swift-format.json`) and CI linting.
- Improve repository README (badges, installation, FAQ, submodule policy).
- Add community health files (contributing guide, code of conduct, security policy, issue/PR templates).
- Document release process and changelog workflow.
- Add informal `Benchmarks` executable target for performance spot checks.

## [0.1.0] - TBD
- Initial public release of `swift-zstd` with:
  - One-shot, streaming, async sequence, and file-handle APIs over Zstandard.
  - Dictionary training/loading helpers.
  - Safety limits for decompression, window log, and output size.
  - Bundled Zstandard `v1.5.7` submodule.

[Unreleased]: https://github.com/Apurer/swift-zstd/compare/main...HEAD
[0.1.0]: https://github.com/Apurer/swift-zstd/releases/tag/v0.1.0
