# macOS build of gbe_fork's "api_regular" target (libsteam_api.dylib).
#
# This mirrors the `api_regular` project in upstream premake5.lua, which only
# targets Windows and Linux. Driven by scripts/build-gbe-macos.sh, which passes:
#   GBE_SOURCE_DIR   patched gbe_fork checkout (with proto_gen/macos generated)
#   GBE_DEPS_PREFIX  per-arch install prefix of protobuf/abseil, mbedtls, libssq
#   GBE_BUILD_STRING value for EMU_BUILD_STRING
#
# Differences from the Linux build (see README.md):
#   - no CONTROLLER_SUPPORT: libs/gamepad has no macOS backend
#   - voice chat replaced by src/voicechat_stub.cpp (no opus/portaudio)
#   - curl and zlib come from the macOS SDK (/usr/lib) instead of static builds
#   - dll/wrap.cpp (Linux --wrap file hooks) compiles to nothing on macOS
cmake_minimum_required(VERSION 3.24)
project(gbe_macos LANGUAGES C CXX)

if(NOT GBE_SOURCE_DIR OR NOT GBE_DEPS_PREFIX)
  message(FATAL_ERROR "GBE_SOURCE_DIR and GBE_DEPS_PREFIX are required")
endif()
set(GBE_BUILD_STRING "playden-macos" CACHE STRING "EMU_BUILD_STRING")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS ON)
set(CMAKE_C_STANDARD 17)
set(CMAKE_C_EXTENSIONS ON)

find_package(absl CONFIG REQUIRED PATHS "${GBE_DEPS_PREFIX}" NO_DEFAULT_PATH)
find_package(utf8_range CONFIG REQUIRED PATHS "${GBE_DEPS_PREFIX}" NO_DEFAULT_PATH)
find_package(protobuf CONFIG REQUIRED PATHS "${GBE_DEPS_PREFIX}" NO_DEFAULT_PATH)
find_package(MbedTLS CONFIG REQUIRED PATHS "${GBE_DEPS_PREFIX}" NO_DEFAULT_PATH)

set(S "${GBE_SOURCE_DIR}")
file(GLOB GBE_DLL_SOURCES CONFIGURE_DEPENDS "${S}/dll/*.cpp")
list(REMOVE_ITEM GBE_DLL_SOURCES "${S}/dll/voicechat.cpp")
file(GLOB_RECURSE GBE_PROTO_SOURCES CONFIGURE_DEPENDS "${S}/proto_gen/macos/*.cc")
if(NOT GBE_PROTO_SOURCES)
  message(FATAL_ERROR "no generated protobuf sources in ${S}/proto_gen/macos")
endif()

add_library(steam_api SHARED
  ${GBE_DLL_SOURCES}
  ${GBE_PROTO_SOURCES}
  "${S}/libs/simpleini/ConvertUTF.c"
  "${S}/crash_printer/linux.cpp"
  "${S}/helpers/common_helpers.cpp"
  "${S}/helpers/dbg_log.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/voicechat_stub.cpp"
)

set_target_properties(steam_api PROPERTIES
  OUTPUT_NAME steam_api                 # -> libsteam_api.dylib
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
  # Match Valve's macOS library exactly.
  INSTALL_NAME_DIR "@loader_path"
  BUILD_WITH_INSTALL_NAME_DIR ON
  # No VERSION/SOVERSION: the file must be plain libsteam_api.dylib.
  MACHO_COMPATIBILITY_VERSION 1.0.0
  MACHO_CURRENT_VERSION 1.0.0
)

target_include_directories(steam_api PRIVATE
  "${S}/dll"
  "${S}/proto_gen/macos"
  "${S}/libs"
  "${S}/libs/utfcpp"
  "${S}/helpers"
  "${S}/crash_printer"
  "${S}/sdk"
  "${S}/overlay_experimental"
  "${GBE_DEPS_PREFIX}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

target_compile_definitions(steam_api PRIVATE
  UTF_CPP_CPLUSPLUS=201703L
  "EMU_BUILD_STRING=${GBE_BUILD_STRING}"
  NDEBUG EMU_RELEASE_BUILD
  GNUC
  EMU_NO_VOICECHAT
)

target_compile_options(steam_api PRIVATE
  -O2
  -fno-jump-tables
  -Wno-switch
  -Wno-deprecated-declarations
  -Wno-unused-command-line-argument
)

target_link_libraries(steam_api PRIVATE
  protobuf::libprotobuf
  MbedTLS::mbedtls MbedTLS::mbedx509 MbedTLS::mbedcrypto
  "${GBE_DEPS_PREFIX}/lib/libssq.a"
  "${CMAKE_OSX_SYSROOT}/usr/lib/libcurl.tbd"
  "${CMAKE_OSX_SYSROOT}/usr/lib/libz.tbd"
)

target_link_options(steam_api PRIVATE
  -Wl,-dead_strip
  # Only the Steam API should be exported (like Valve's library). On x86_64 the
  # libc++ headers give some std:: typeinfo default visibility; hide it.
  "-Wl,-unexported_symbol,__ZTINSt3__1*"
  "-Wl,-unexported_symbol,__ZTSNSt3__1*"
)
