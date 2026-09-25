# Smart mirror firmware.
#
# The render core is not vendored here. components/mirror_core is a symlink to
# the repository's core directory, so the firmware and the desktop designer
# compile literally the same source files. That is what makes the designer's
# preview trustworthy, and it is worth the slightly unusual layout.
#
# Build:
#   . $HOME/esp/esp-idf/export.sh
#   idf.py set-target esp32s3
#   idf.py menuconfig      # WiFi credentials, timezone, panel geometry
#   idf.py flash monitor

cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

# RULE: bump this version on every firmware change. The version is baked into
# the app image descriptor and is what /api/status, the BLE pong and the OTA
# filename report. Never reuse a version for a different build: two builds
# that share a version are indistinguishable on the board and over OTA.
#
# Enforced rather than merely stated: this configure step, every app build that
# stages the image (tools/bundle_firmware.sh) and the OTA build all run
# tools/firmware_version.py, which fails when the sources the image is built
# from have changed since this version was stamped. See firmware/README.md,
# Versioning, for the two commands that clear it.
execute_process(
    COMMAND python3 "${CMAKE_CURRENT_LIST_DIR}/../tools/firmware_version.py" check
    WORKING_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}"
    RESULT_VARIABLE _firmware_version_check
    OUTPUT_VARIABLE _firmware_version_out
    ERROR_VARIABLE _firmware_version_err)
if(NOT _firmware_version_check EQUAL 0)
    message(FATAL_ERROR
        "firmware version check:\n${_firmware_version_err}${_firmware_version_out}")
endif()

project(smart_mirror VERSION 0.3.4)
