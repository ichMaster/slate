idf_component_register(
    SRCS
        "main.c"
        "panel_probe.c"
        "xml_poc.c"
        "applicator.c"
        "net.c"
    INCLUDE_DIRS "."
    REQUIRES
        # WiFi reaches the C6 through esp_wifi_remote, but the API surface — and
        # so the dependency — is the ordinary esp_wifi one.
        esp_wifi
        esp_netif
        esp_event
        nvs_flash
        esp_http_client
        json
        esp_lcd
        # The touch drivers are transitive dependencies of the BSP, so their
        # headers are not visible here unless named: panel_probe.c needs the two
        # controllers' I2C addresses to tell the board revisions apart.
        espressif__m5stack_tab5
        espressif__esp_lcd_touch_gt911
        espressif__esp_lcd_touch_st7123
        espressif__esp_websocket_client
    # The M0 page also travels in the binary, so the lv_xml verdict can be taken
    # before the network is up: a WiFi failure must not be able to erase the one
    # measurement this milestone exists to produce. It is the same file the
    # server serves, not a copy.
    EMBED_TXTFILES "../../apps/m0.xml"
)
