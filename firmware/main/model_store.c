#include "model_store.h"

#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

static const char *TAG = "model";

static ml_model          s_model;
static SemaphoreHandle_t s_lock;

esp_err_t model_store_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) {
        ESP_LOGE(TAG, "could not create the model mutex");
        return ESP_ERR_NO_MEM;
    }
    ml_model_init(&s_model);
    return ESP_OK;
}

void model_store_lock(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
}

void model_store_unlock(void)
{
    xSemaphoreGive(s_lock);
}

ml_model *model_store_locked(void)
{
    return &s_model;
}

void model_store_snapshot(ml_model *out)
{
    if (out == NULL) return;

    /* Before init, hand back an empty model rather than garbage: the render
     * task starts first on purpose, so the panel shows placeholders within a
     * second of power-on. */
    if (s_lock == NULL) {
        ml_model_init(out);
        return;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    memcpy(out, &s_model, sizeof(*out));
    xSemaphoreGive(s_lock);
}
