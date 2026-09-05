#include "net.h"

#include <stdio.h>
#include <string.h>

#include "bsp/m5stack_tab5.h"
#include "cJSON.h"
#include "esp_event.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_websocket_client.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "nvs_flash.h"

static const char *TAG = "slate.net";

#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAILED_BIT    BIT1
#define WIFI_MAX_RETRY     8
#define WIFI_TIMEOUT_MS    30000

static EventGroupHandle_t s_wifi_events;
static int s_retries;

static esp_websocket_client_handle_t s_ws;
static slate_update_cb_t s_on_update;
static bool s_connected;
static int s_req_id;

/* The device mints the session id and the server creates the session lazily on
 * first sight of it — first use *is* creation, and there is no handshake to get
 * wrong (ARCHITECTURE.md §Protocol).
 */
static char s_session_id[16];

const char *slate_session_id(void)
{
    if (s_session_id[0] == '\0') {
        snprintf(s_session_id, sizeof(s_session_id), "s-%04" PRIx32, esp_random() & 0xFFFF);
    }
    return s_session_id;
}

/* -- WiFi ------------------------------------------------------------------ */

static void wifi_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        if (s_retries < WIFI_MAX_RETRY) {
            s_retries++;
            ESP_LOGW(TAG, "wifi disconnected, retry %d/%d", s_retries, WIFI_MAX_RETRY);
            esp_wifi_connect();
        } else {
            xEventGroupSetBits(s_wifi_events, WIFI_FAILED_BIT);
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)data;
        ESP_LOGI(TAG, "SLATE_LEDGER wifi_ip=" IPSTR, IP2STR(&event->ip_info.ip));
        s_retries = 0;
        xEventGroupSetBits(s_wifi_events, WIFI_CONNECTED_BIT);
    }
}

bool slate_wifi_power_on(void)
{
    /* Same shape as the touch controller needing the LCD rail: on this board the
     * IO expanders gate more than their names suggest, and a peripheral that is
     * merely unpowered fails as though its driver were broken.
     */
    const esp_err_t ret = bsp_feature_enable(BSP_FEATURE_WIFI, true);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "could not power the C6: %s", esp_err_to_name(ret));
        return false;
    }
    /* The C6 needs a moment to boot its hosted-slave firmware before the SDIO
     * link is probed.
     */
    vTaskDelay(pdMS_TO_TICKS(500));
    ESP_LOGI(TAG, "C6 powered");
    return true;
}

bool slate_wifi_connect(void)
{
    if (strlen(CONFIG_SLATE_WIFI_SSID) == 0) {
        ESP_LOGE(TAG, "no SSID configured — set SLATE_WIFI_SSID in sdkconfig.defaults.local");
        return false;
    }

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    s_wifi_events = xEventGroupCreate();
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                        wifi_event_handler, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                        wifi_event_handler, NULL, NULL));

    wifi_config_t wifi_config = {0};
    strncpy((char *)wifi_config.sta.ssid, CONFIG_SLATE_WIFI_SSID,
            sizeof(wifi_config.sta.ssid) - 1);
    strncpy((char *)wifi_config.sta.password, CONFIG_SLATE_WIFI_PASSWORD,
            sizeof(wifi_config.sta.password) - 1);

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "joining \"%s\"", CONFIG_SLATE_WIFI_SSID);
    EventBits_t bits = xEventGroupWaitBits(s_wifi_events, WIFI_CONNECTED_BIT | WIFI_FAILED_BIT,
                                           pdFALSE, pdFALSE, pdMS_TO_TICKS(WIFI_TIMEOUT_MS));
    if ((bits & WIFI_CONNECTED_BIT) == 0) {
        ESP_LOGE(TAG, "wifi did not associate within %d ms", WIFI_TIMEOUT_MS);
        return false;
    }
    return true;
}

/* -- HTTP: the page, once, at boot ----------------------------------------- */

size_t slate_http_fetch_page(char *out, size_t out_size)
{
    char url[160];
    snprintf(url, sizeof(url), "http://%s:%d%s", CONFIG_SLATE_SERVER_HOST, CONFIG_SLATE_SERVER_PORT,
             CONFIG_SLATE_PAGE_PATH);

    esp_http_client_config_t config = {
        .url = url,
        .timeout_ms = 10000,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        return 0;
    }

    size_t total = 0;
    esp_err_t err = esp_http_client_open(client, 0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "GET %s failed to open: %s", url, esp_err_to_name(err));
        esp_http_client_cleanup(client);
        return 0;
    }

    const int64_t content_length = esp_http_client_fetch_headers(client);
    const int status = esp_http_client_get_status_code(client);
    if (status != 200) {
        ESP_LOGE(TAG, "GET %s returned %d", url, status);
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        return 0;
    }
    (void)content_length;

    int read = 0;
    while (total + 1 < out_size
           && (read = esp_http_client_read(client, out + total, (int)(out_size - total - 1))) > 0) {
        total += (size_t)read;
    }
    out[total] = '\0';

    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    ESP_LOGI(TAG, "SLATE_LEDGER page_fetch_bytes=%u from=%s", (unsigned)total, url);
    return total;
}

/* -- The wire -------------------------------------------------------------- */

/* One `data` frame. Each update is handed to the applicator by id; an update
 * naming an id the page does not have is the applicator's business to drop.
 */
static void handle_data_frame(cJSON *root)
{
    cJSON *updates = cJSON_GetObjectItem(root, "updates");
    if (!cJSON_IsArray(updates)) {
        return;
    }
    cJSON *update = NULL;
    cJSON_ArrayForEach(update, updates)
    {
        cJSON *id = cJSON_GetObjectItem(update, "id");
        if (!cJSON_IsString(id) || s_on_update == NULL) {
            continue;
        }
        char *json = cJSON_PrintUnformatted(update);
        if (json != NULL) {
            s_on_update(id->valuestring, json);
            cJSON_free(json);
        }
    }
}

static void on_frame(const char *payload, int len)
{
    cJSON *root = cJSON_ParseWithLength(payload, (size_t)len);
    if (root == NULL) {
        ESP_LOGW(TAG, "ignoring unparseable frame");
        return;
    }

    cJSON *type = cJSON_GetObjectItem(root, "type");
    if (cJSON_IsString(type) && strcmp(type->valuestring, "data") == 0) {
        handle_data_frame(root);
    } else {
        /* Unknown message types are ignored, never errors — forward
         * compatibility is a protocol guarantee, and it starts here.
         */
        ESP_LOGD(TAG, "ignoring message type %s",
                 cJSON_IsString(type) ? type->valuestring : "(none)");
    }
    cJSON_Delete(root);
}

static void ws_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    esp_websocket_event_data_t *event = (esp_websocket_event_data_t *)data;

    switch (id) {
    case WEBSOCKET_EVENT_CONNECTED:
        s_connected = true;
        ESP_LOGI(TAG, "wire open, session %s", slate_session_id());
        break;
    case WEBSOCKET_EVENT_DISCONNECTED:
        s_connected = false;
        ESP_LOGW(TAG, "wire closed");
        break;
    case WEBSOCKET_EVENT_DATA:
        if (event->op_code == 0x01 && event->data_len > 0) { /* text frame */
            on_frame(event->data_ptr, event->data_len);
        }
        break;
    default:
        break;
    }
}

bool slate_wire_start(slate_update_cb_t on_update)
{
    s_on_update = on_update;

    char url[128];
    /* Plain /ws with no proto/screen params: the connect-URL contract lands at
     * v1.2, and v0.1 must not pre-empt it.
     */
    snprintf(url, sizeof(url), "ws://%s:%d/ws", CONFIG_SLATE_SERVER_HOST,
             CONFIG_SLATE_SERVER_PORT);

    esp_websocket_client_config_t config = {
        .uri = url,
        .reconnect_timeout_ms = 5000,
        .network_timeout_ms = 10000,
    };
    s_ws = esp_websocket_client_init(&config);
    if (s_ws == NULL) {
        return false;
    }
    esp_websocket_register_events(s_ws, WEBSOCKET_EVENT_ANY, ws_event_handler, NULL);
    return esp_websocket_client_start(s_ws) == ESP_OK;
}

bool slate_wire_connected(void)
{
    return s_connected;
}

static void send_json(cJSON *frame)
{
    char *text = cJSON_PrintUnformatted(frame);
    if (text != NULL) {
        esp_websocket_client_send_text(s_ws, text, (int)strlen(text), portMAX_DELAY);
        cJSON_free(text);
    }
    cJSON_Delete(frame);
}

void slate_wire_subscribe(const char *page, const char *const *widgets, size_t count)
{
    cJSON *frame = cJSON_CreateObject();
    cJSON_AddStringToObject(frame, "type", "subscribe");
    cJSON_AddStringToObject(frame, "session_id", slate_session_id());
    cJSON_AddNumberToObject(frame, "req_id", ++s_req_id);
    cJSON_AddStringToObject(frame, "page", page);

    cJSON *array = cJSON_AddArrayToObject(frame, "widgets");
    for (size_t i = 0; i < count; i++) {
        cJSON_AddItemToArray(array, cJSON_CreateString(widgets[i]));
    }
    send_json(frame);
}

void slate_wire_event(const char *action, const char *source)
{
    cJSON *frame = cJSON_CreateObject();
    cJSON_AddStringToObject(frame, "type", "event");
    cJSON_AddStringToObject(frame, "session_id", slate_session_id());
    cJSON_AddStringToObject(frame, "action", action);
    cJSON_AddStringToObject(frame, "source", source);
    /* `values` carries every input field on the page. M0 has none, but the key
     * ships from the start so the shape never changes.
     */
    cJSON_AddItemToObject(frame, "values", cJSON_CreateObject());
    send_json(frame);
}
