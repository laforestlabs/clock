idf_component_register(
    SRCS
        "main.c"
        "panel.cpp"
        "model_store.c"
        "net/wifi.c"
        "net/provision.c"
        "net/sntp_time.c"
        "net/http_get.c"
        "providers/provider.c"
        "providers/openmeteo.c"
    INCLUDE_DIRS
        "."
    REQUIRES
        mirror_core
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
    # The default layout is baked into the binary so the panel shows something
    # useful before anything has been pushed to it. It is the same file the
    # designer and the golden tests use, not a copy.
    EMBED_TXTFILES
        "${CMAKE_CURRENT_LIST_DIR}/../../layouts/mini.json"
)
