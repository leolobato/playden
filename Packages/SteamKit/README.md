# SteamKit

Big Screen's in-repository Steam library. The `SteamCore` product provides authentication,
library metadata, entitlement lookup, downloads, Steam Cloud primitives and game preparation.
`SteamProto` contains generated protocol messages; `CLzma` and `CZstd` bind the compression
libraries installed with `brew install xz zstd`.

```sh
swift test --package-path Packages/SteamKit
```

Generated Swift sources and their `.proto` inputs are checked in. To regenerate them, install
`protobuf` and `swift-protobuf` with Homebrew, then run `Packages/SteamKit/protos/regen.sh`.
See that script for upstream protocol sources and the enum compatibility patch.

The initial import comes from the Steam-only targets and tests in `GameNative-macos/swift`
at commit `608a619ee02e0a56ca223dd732d807b013330658`. Subsequent changes live in this repository;
no sibling checkout is needed. The research project's CLI, VM runtime and viewer were not imported.
Original resource attribution and hashes remain in
[steampipe/PROVENANCE.md](Sources/SteamCore/Resources/steampipe/PROVENANCE.md).

The `.gn-download` state directory is an existing on-disk format used by resumable downloads.
Its name is retained so existing downloads and their locks remain compatible.
