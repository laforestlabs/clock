idf_component_register(
    SRCS
        "main.c"
        "panel.cpp"
        "config.c"
        "layout_store.c"
        "model_store.c"
        "netlog.c"
        "net/wifi.c"
        "net/provision.c"
        "net/sntp_time.c"
        "net/http_get.c"
        "net/api_server.c"
        "net/ota.c"
        "net/flash_write.c"
        "net/ble.c"
        "games/game_runner.c"
        "providers/provider.c"
        "providers/openmeteo.c"
    INCLUDE_DIRS
        "."
    REQUIRES
        mirror_core
        gamekit
        nvs_flash
        esp_wifi
        esp_netif
        esp_event
        esp_timer
        lwip
        # Setup portal web server.
        esp_http_server
        # HTTPS for the data providers. esp-tls brings in the bundled root
        # certificate store, so no per-service certificate has to be pinned.
        esp_http_client
        esp-tls
        mbedtls
        # Pushed layouts survive reboots on the storage partition.
        spiffs
        # LAN API mDNS advertisement (smart-mirror.local).
        mdns
        # OTA: esp_ota_* partition switching and rollback marking.
        app_update
        # NimBLE GATT server for the phone's config + layout push.
        bt
    # The default layout is baked into the binary so the panel shows something
    # useful before anything has been pushed to it. It is the same file the
    # designer and the golden tests use, not a copy.
    EMBED_TXTFILES
        "${CMAKE_CURRENT_LIST_DIR}/../../layouts/mini.json"
)
