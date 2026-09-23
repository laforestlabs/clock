/*
 * flash_write.c - a single task whose stack is in internal DRAM, used to run
 * flash writes that must not run on a PSRAM-backed task (see flash_write.h).
 *
 * The stack is static so it lives in internal DRAM at link time and is not
 * subject to the fragmented internal heap. Callers are serialized by a binary
 * semaphore; the writer may release it after synchronous or asynchronous jobs.
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
        xSemaphoreGive(s_mutex);
    }
}

void flash_write_init(void)
{
    s_mutex = xSemaphoreCreateBinary();
    s_ready = xSemaphoreCreateBinary();
    s_done = xSemaphoreCreateBinary();
    if (s_mutex == NULL || s_ready == NULL || s_done == NULL) {
        ESP_LOGE("flash_write", "could not create synchronization objects");
        return;
    }
    xSemaphoreGive(s_mutex);

    TaskHandle_t handle = xTaskCreateStatic(flash_writer_task, "flash_write",
                                            FLASH_WRITER_STACK_WORDS, NULL,
                                            5, s_stack, &s_tcb);
    if (handle == NULL) {
        ESP_LOGE("flash_write", "could not create the writer task");
    }
}

static esp_err_t flash_write_acquire(void (*fn)(void *ctx), void *ctx)
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
    return ESP_OK;
}

esp_err_t flash_write_submit(void (*fn)(void *ctx), void *ctx)
{
    return flash_write_acquire(fn, ctx);
}

esp_err_t flash_write_run(void (*fn)(void *ctx), void *ctx)
{
    const esp_err_t err = flash_write_acquire(fn, ctx);
    if (err != ESP_OK) return err;
    /* An async job leaves its "done" credit behind: without draining it here
     * the wait below would return before this job had run. */
    xSemaphoreTake(s_done, 0);
    xSemaphoreTake(s_done, portMAX_DELAY);
    return ESP_OK;
}
