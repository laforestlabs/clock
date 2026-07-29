# Builds the shared render core for whichever platform Flutter is targeting.
#
# Every platform's generated build file (android/build.gradle,
# linux/CMakeLists.txt, windows/CMakeLists.txt, and the macOS and iOS podspecs)
# points here, so this is the single place the native sources are listed.
#
# The C is not copied into this package. It is compiled straight out of the
# repository's core directory, because the firmware compiles those exact files
# too. Two copies would drift, and the entire point of the architecture is that
# the designer and the panel run the same renderer.

cmake_minimum_required(VERSION 3.10)
# Named _library so it does not collide with the per-platform projects that
# add_subdirectory this file. That is the convention Flutter's own plugin_ffi
# template uses, and the generated linux and windows CMakeLists assume it.
project(mirror_core_ffi_library VERSION 0.1.0 LANGUAGES C)

# Locate the repository's core directory.
#
# Two things make a fixed relative path unreliable here. Flutter symlinks this
# package into <platform>/flutter/ephemeral/.plugin_symlinks/ before building,
# so CMAKE_CURRENT_LIST_DIR is the symlinked path and "../../.." counts levels
# in the wrong tree. And the nesting depth differs between platforms.
#
# So: resolve the real location first, then walk up looking for the marker.
get_filename_component(_mirror_probe "${CMAKE_CURRENT_LIST_DIR}" REALPATH)

set(MIRROR_CORE "")
foreach(_level RANGE 8)
    if(EXISTS "${_mirror_probe}/core/ffi/mirror_ffi.c")
        set(MIRROR_CORE "${_mirror_probe}/core")
        break()
    endif()
    get_filename_component(_mirror_probe "${_mirror_probe}" DIRECTORY)
endforeach()

if(MIRROR_CORE STREQUAL "")
    message(FATAL_ERROR
        "Cannot find the render core.\n"
        "Searched upward from ${CMAKE_CURRENT_LIST_DIR} (resolved) for "
        "core/ffi/mirror_ffi.c.\n"
        "This package must stay inside the smart-mirror repository; it "
        "compiles core/ in place rather than vendoring a copy.")
endif()

message(STATUS "mirror: compiling the render core from ${MIRROR_CORE}")

# Generated glyph tables are committed, but a stale checkout would fail here
# with a confusing linker error rather than an obvious one.
if(NOT EXISTS "${MIRROR_CORE}/src/fonts/font_registry.c")
    message(FATAL_ERROR
        "Font tables are missing. Run: python3 tools/fontgen.py")
endif()

add_library(mirror_core_ffi SHARED
    "${MIRROR_CORE}/src/canvas.c"
    "${MIRROR_CORE}/src/color.c"
    "${MIRROR_CORE}/src/font.c"
    "${MIRROR_CORE}/src/gamma_table.c"
    "${MIRROR_CORE}/src/json.c"
    "${MIRROR_CORE}/src/layout_json.c"
    "${MIRROR_CORE}/src/mock.c"
    "${MIRROR_CORE}/src/model.c"
    "${MIRROR_CORE}/src/render.c"
    "${MIRROR_CORE}/src/fonts/font_registry.c"
    "${MIRROR_CORE}/src/fonts/font_tom5x7.c"
    "${MIRROR_CORE}/src/fonts/font_digits16.c"
    "${MIRROR_CORE}/src/fonts/font_wx16.c"
    "${MIRROR_CORE}/ffi/mirror_ffi.c"
)

target_include_directories(mirror_core_ffi PRIVATE
    "${MIRROR_CORE}/include"
    "${MIRROR_CORE}/ffi"
)

set_target_properties(mirror_core_ffi PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED ON
    PUBLIC_HEADER "${MIRROR_CORE}/ffi/mirror_ffi.h"
    OUTPUT_NAME "mirror_core_ffi"
    # Only the ml_sim_* entry points are marked visible, so the exported
    # surface ends up being exactly the documented API.
    C_VISIBILITY_PRESET hidden
)

target_compile_definitions(mirror_core_ffi PUBLIC DART_SHARED_LIB)

if(NOT MSVC)
    target_compile_options(mirror_core_ffi PRIVATE -Wall -Wextra -O2)
endif()

if(ANDROID)
    # Dart's DynamicLibrary.open resolves by SONAME on Android, and the NDK
    # defaults can strip it in release builds.
    target_link_options(mirror_core_ffi PRIVATE
        "-Wl,-z,max-page-size=16384"
        "-Wl,-soname,libmirror_core_ffi.so")
endif()
