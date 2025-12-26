# Contributing

Thanks for helping improve swift-zstd! This guide explains how to propose changes, keep builds green, and prepare releases.

## Ground rules
- Be respectful and follow the [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
- Open an issue before large or breaking changes to align on scope.
- Keep pull requests focused and small; include tests that cover the change.

## Getting started
- Clone with submodules: `git clone --recurse-submodules git@github.com:Apurer/swift-zstd.git`.
- If you already cloned: `git submodule update --init --recursive`.
- Supported toolchains: Swift 6.2+ on macOS 13+ or Linux.

## Development workflow
1. Create a feature branch.
2. Make changes with safety limits in mind (see README FAQ).
3. Run the checks below before opening a PR.

### Formatting
- Configure once: `swift format --help` (tool is bundled with Swift 6 toolchains).
- Lint locally: `swift format lint --configuration swift-format.json Sources Tests`.
- Fix in place: `swift format --in-place --configuration swift-format.json Sources Tests`.

### Tests
- Run unit tests: `swift test --parallel`.
- Linux CI runs on `ubuntu-latest`; macOS CI on `macos-latest`. Make sure platform assumptions are guarded.

### Documentation
- DocC catalog lives at `Sources/Zstd/Documentation.docc`.
- Render locally: `swift package generate-documentation --target Zstd --include-extended-types`.
- Keep code comments and DocC articles aligned.

### Benchmarks
- A lightweight benchmark target is provided: `swift run Benchmarks`.
- Use it to sanity-check performance of one-shot vs streaming APIs and dictionary usage before merging significant changes.

## Release process
- We follow Semantic Versioning. No breaking API changes outside major bumps.
- Before tagging: update `CHANGELOG.md` (add an entry for the version with highlights and zstd submodule version), ensure CI is green, and verify docs build.
- Tag releases as `vX.Y.Z` from the main branch and publish short release notes summarizing changes and risks.

## Opening a pull request
- Fill out the PR template checklist.
- Link related issues.
- Include user-facing notes for changelog/release when relevant.
- Expect a review focused on correctness, safety limits, and portability.
