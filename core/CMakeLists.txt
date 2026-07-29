# Dual-purpose build for the portable render core.
#
# The same directory is consumed two completely different ways:
#
#   ESP-IDF  treats it as a component and calls idf_component_register.
#            The FFI facade is excluded; firmware has no use for it.
#
#   Flutter  compiles it per platform (NDK for Android, Xcode for iOS,
#            CMake for Linux and Windows) via the mirror_core_ffi plugin.
#            The FFI facade is included and its symbols are exported.
#
# The host CLI and tests use Makefile.host instead, which needs nothing but
# gcc, so neither cmake nor ESP-IDF is required just to preview a layout.

set(MIRROR_CORE_SRC
    src/canvas.c
    src/color.c
    src/font.c
    src/gamma_table.c
    src/json.c
    src/layout_json.c
    src/mock.c
    src/model.c
    src/render.c
    src/fonts/font_registry.c
    src/fonts/font_tom5x7.c
    src/fonts/font_digits16.c
    src/fonts/font_wx16.c
)

if(ESP_PLATFORM)
    idf_component_register(
        SRCS ${MIRROR_CORE_SRC}
        INCLUDE_DIRS "include"
    )
    return()
endif()

cmake_minimum_required(VERSION 3.10)
project(mirror_core C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Built shared so Dart's DynamicLibrary can open it. On Android and Windows
# Flutter bundles the result automatically; on desktop Linux it lands in the
# bundle's lib directory.
add_library(mirror_core SHARED
    ${MIRROR_CORE_SRC}
    ffi/mirror_ffi.c
)

target_include_directories(mirror_core PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/ffi"
)

# Only the ml_sim_* entry points carry a visibility attribute, so hiding
# everything else keeps the exported surface exactly the documented API.
set_target_properties(mirror_core PROPERTIES
    C_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    OUTPUT_NAME "mirror_core"
)

if(NOT MSVC)
    target_compile_options(mirror_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

# Flutter's Linux and Windows tooling looks for this to know what to bundle.
if(DEFINED FLUTTER_TARGET_PLATFORM OR DEFINED ENV{FLUTTER_ROOT})
    set(mirror_core_bundled_libraries
        $<TARGET_FILE:mirror_core>
        PARENT_SCOPE
    )
endif()
