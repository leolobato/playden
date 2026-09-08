#!/bin/sh
set -eu
cd "$SRCROOT"
# Build a tiny Windows executable using the existing LLVM cross compiler and linker.
# No downloaded runtime, Windows SDK, .NET, or additional user permissions are required.
compiler_root="${BIGSCREEN_LLVM_ROOT:-/opt/homebrew/opt/llvm}"
linker_root="${BIGSCREEN_LLD_ROOT:-/opt/homebrew/opt/lld}"
helper_build="$DERIVED_FILE_DIR/DisplayHelper"
helper_resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$helper_build" "$helper_resources"
"$compiler_root/bin/clang" --target=x86_64-pc-windows-msvc -std=c11 -Os -Wall -Wextra -Werror \
    -ffreestanding -fno-builtin -fno-stack-protector -c Native/DisplayHelper/main.c -o "$helper_build/main.obj"
for library in kernel32 user32 shell32 ole32 advapi32; do
    "$compiler_root/bin/llvm-dlltool" -m i386:x86-64 -d "Native/DisplayHelper/$library.def" -l "$helper_build/$library.lib"
done
"$linker_root/bin/lld-link" /nodefaultlib /entry:mainCRTStartup /subsystem:console /machine:x64 /timestamp:0 \
    "/out:$helper_resources/BigScreenDisplay.exe" "$helper_build/main.obj" \
    "$helper_build/kernel32.lib" "$helper_build/user32.lib" "$helper_build/shell32.lib" "$helper_build/ole32.lib" "$helper_build/advapi32.lib"
