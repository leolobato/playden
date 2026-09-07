#!/bin/sh
set -eu
# SteamCore's system-library dependencies must ship with the app rather than resolve via Homebrew.
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$frameworks"
for entry in xz:liblzma.5.dylib zstd:libzstd.1.dylib; do
    formula=${entry%%:*}
    library=${entry#*:}
    source_path="/opt/homebrew/opt/$formula/lib/$library"
    test -f "$source_path"
    cp -f "$source_path" "$frameworks/$library"
    chmod u+w "$frameworks/$library"
    /usr/bin/install_name_tool -id "@rpath/$library" "$frameworks/$library"
    /usr/bin/codesign --force --sign - "$frameworks/$library"
    for binary in "$TARGET_BUILD_DIR/$EXECUTABLE_PATH" "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/$PRODUCT_NAME.debug.dylib"; do
        if test -f "$binary"; then
            /usr/bin/install_name_tool -change "$source_path" "@rpath/$library" "$binary"
        fi
    done
done
licenses="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Licenses"
mkdir -p "$licenses"
cp /opt/homebrew/opt/xz/share/doc/xz/COPYING.0BSD "$licenses/liblzma.txt"
cp /opt/homebrew/opt/zstd/LICENSE "$licenses/zstd.txt"
