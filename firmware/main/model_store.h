/*
 * model_store.h - the one ml_model the whole firmware shares.
 *
 * Providers write to it from their own task; the render task reads it twice a
 * second. ml_model is a couple of hundred bytes of plain data, so the cheapest
 * correct answer is a mutex plus a memcpy rather than anything lock-free.
 *
 * The rule that matters: never hold the lock across network I/O. Providers
 * fetch into their own storage first and take the lock only for the copy, so
 * a stalled HTTPS request can never block a frame.
 */
#ifndef MIRROR_MODEL_STORE_H
#define MIRROR_MODEL_STORE_H

#include "esp_err.h"
#include "mirror/model.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t model_store_init(void);

/*
 * Copy the shared model out. The render task uses this and then draws from its
 * private copy, so rendering never holds the lock and a provider is never
 * blocked by a frame in progress.
 */
void model_store_snapshot(ml_model *out);

/*
 * Direct access for writers. Must be bracketed by lock and unlock, and must
 * not perform I/O in between.
 */
void      model_store_lock(void);
void      model_store_unlock(void);
ml_model *model_store_locked(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_MODEL_STORE_H */
