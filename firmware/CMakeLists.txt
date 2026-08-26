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
project(smart_mirror VERSION 0.2.19)
