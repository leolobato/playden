#!/usr/bin/env bash
# Regenerate Sources/SteamProto/Generated from the vendored .proto files.
#
# The protos come from https://github.com/SteamDatabase/Protobufs (steam/),
# the same upstream SteamKit2 and JavaSteam track. To refresh them, re-curl the
# files listed below, then re-apply the one local patch:
#
#   enums.proto: k_EAppTypeDepotOnly = -2147483648 (Int32.min) crashes
#   protoc-gen-swift 1.38.1 (EnumGenerator.generateProtoNameProviding trap);
#   we change it to -2147483647. We never consume EProtoAppType, so the wire
#   value mismatch is irrelevant.
#
# Prereqs: brew install protobuf swift-protobuf
set -euo pipefail
cd "$(dirname "$0")/.."
protoc --swift_out=Sources/SteamProto/Generated \
       --swift_opt=Visibility=Public \
       --proto_path=protos/steam protos/steam/*.proto
echo "regenerated: $(ls Sources/SteamProto/Generated | wc -l | tr -d ' ') files"
