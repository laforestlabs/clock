idf_component_register(
    SRCS
        "main.c"
        "panel.cpp"
        "net/wifi.c"
        "net/sntp_time.c"
    INCLUDE_DIRS
        "."
        "net"
    REQUIRES
        mirror_core
        nvs_flash
        esp_wifi
        esp_netif
        esp_event
        esp_timer
        lwip
    # The default layout is baked into the binary so the panel shows something
    # useful before anything has been pushed to it. It is the same file the
    # designer and the golden tests use, not a copy.
    EMBED_TXTFILES
        "${CMAKE_CURRENT_LIST_DIR}/../../layouts/dual.json"
)
