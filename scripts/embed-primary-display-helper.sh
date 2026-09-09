#!/bin/sh
set -eu
cd "$SRCROOT"
helper_build="$DERIVED_FILE_DIR/PrimaryDisplayHelper"
helper_resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$helper_build" "$helper_resources"
set --
for arch in $ARCHS; do
    binary="$helper_build/PlaydenPrimaryDisplay-$arch"
    xcrun swiftc -O -swift-version 6 -sdk "$SDKROOT" \
        -target "${arch}-apple-macosx${MACOSX_DEPLOYMENT_TARGET}" \
        Packages/PlaydenKit/Sources/Runner/PrimaryDisplayLayout.swift \
        Native/PrimaryDisplayHelper/main.swift -o "$binary"
    set -- "$@" "$binary"
done
xcrun lipo -create "$@" -output "$helper_resources/PlaydenPrimaryDisplay"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
    # Distribution builds request a secure timestamp for every nested executable.
    case " ${OTHER_CODE_SIGN_FLAGS:-} " in
        *" --timestamp "*) set -- --timestamp ;;
        *) set -- --timestamp=none ;;
    esac
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
        --options runtime "$@" "$helper_resources/PlaydenPrimaryDisplay"
fi
