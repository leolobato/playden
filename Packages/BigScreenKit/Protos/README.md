# Steam Cloud wire definitions

`cloud_read.proto` and `cloud_write.proto` contain selected message subsets of
[SteamDatabase/Protobufs](https://github.com/SteamDatabase/Protobufs/blob/b008ad5896440fabc63852440f695b3569e6647c/steam/steammessages_cloud.steamclient.proto),
revision `b008ad5896440fabc63852440f695b3569e6647c`, inspected 7 September 2026.
The sibling GameNative Android implementation uses these messages through JavaSteam.

The local package namespace avoids collisions with SteamCore's generated types. Wire field
numbers/types are unchanged. `persist_state` uses its wire-compatible int32 representation:
0 persisted, 1 forgotten, 2 deleted, from the upstream `enums.proto`. The decoder rejects unknown
values. Listing/download and upload-batch messages are included; no unrelated service definitions
or dependencies are generated. The uploader calls CompleteAppUploadBatchBlocking to receive an
acknowledgement, and handles the HTTP method/explicit body in each transfer instruction. HTTP
method numbers follow the [Steamworks EHTTPMethod definition](https://partner.steamgames.com/doc/api/ISteamHTTP#EHTTPMethod).

Regenerate from the repository root (Homebrew protobuf and swift-protobuf):

```sh
protoc --swift_out=Packages/BigScreenKit/Sources/SteamCloudProto \
  --swift_opt=Visibility=Public --proto_path=Packages/BigScreenKit/Protos \
  Packages/BigScreenKit/Protos/cloud_read.proto Packages/BigScreenKit/Protos/cloud_write.proto
```

Generated files are checked in. This does not change the sibling SteamCore repository.
