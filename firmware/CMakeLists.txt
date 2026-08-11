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

# The version is baked into the app image descriptor (esp_app_get_description)
# and is what /api/status, the BLE pong and the OTA filename report. Bump it
# for every release so an OTA update is observable end to end.
project(smart_mirror VERSION 0.2.0)
