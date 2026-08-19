/*
 * flash_write.c - a single task whose stack is in internal DRAM, used to run
 * flash writes that must not run on a PSRAM-backed task (see flash_write.h).
 *
 * The stack is static so it lives in internal DRAM at link time and is not
 * subject to the fragmented internal heap, which has only ~15KB free at
 * runtime. Callers are serialized by a mutex, so the one job slot and the
 * binary "done" semaphore stay unambiguous.
 */
#include "flash_write.h"

#include "esp_log.h"

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define FLASH_WRITER_STACK_WORDS 4096 /* 16 KB */
typedef struct {
    void (*fn)(void *ctx);
    void *ctx;
} flash_write_job_t;

static flash_write_job_t s_job;
static SemaphoreHandle_t s_mutex; /* serializes callers */
static SemaphoreHandle_t s_ready; /* caller -> writer: a job is available */
static SemaphoreHandle_t s_done;  /* writer -> caller: the job finished */
static StackType_t s_stack[FLASH_WRITER_STACK_WORDS];
static StaticTask_t s_tcb;

static void flash_writer_task(void *arg)
{
    (void)arg;
    for (;;) {
        xSemaphoreTake(s_ready, portMAX_DELAY);
        s_job.fn(s_job.ctx);
        xSemaphoreGive(s_done);
    }
}

void flash_write_init(void)
{
    s_mutex = xSemaphoreCreateMutex();
    s_ready = xSemaphoreCreateBinary();
    s_done = xSemaphoreCreateBinary();
    if (s_mutex == NULL || s_ready == NULL || s_done == NULL) {
        ESP_LOGE("flash_write", "could not create synchronization objects");
        return;
    }

    TaskHandle_t handle = xTaskCreateStatic(flash_writer_task, "flash_write",
                                            FLASH_WRITER_STACK_WORDS, NULL,
                                            5, s_stack, &s_tcb);
    if (handle == NULL) {
        ESP_LOGE("flash_write", "could not create the writer task");
    }
}

esp_err_t flash_write_run(void (*fn)(void *ctx), void *ctx)
{
    if (s_mutex == NULL || s_ready == NULL || s_done == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    if (xSemaphoreTake(s_mutex, portMAX_DELAY) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    s_job.fn = fn;
    s_job.ctx = ctx;
    xSemaphoreGive(s_ready);
    xSemaphoreTake(s_done, portMAX_DELAY);
    xSemaphoreGive(s_mutex);
    return ESP_OK;
}
