/*
 * sntp_time.h - wall clock.
 *
 * The render core never reads a clock; time arrives through ml_model. This is
 * where the device fills that in.
 */
#ifndef MIRROR_SNTP_TIME_H
#define MIRROR_SNTP_TIME_H

#include <stdbool.h>

#include "mirror/model.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Applies the configured timezone and starts periodic SNTP. Returns
 * immediately; the first sync lands a few seconds later. */
void sntp_time_start(void);

/*
 * Fills m->now from the system clock, setting valid only once the time is
 * plausible. Before the first sync the clock reads 1970, and rendering that
 * would put a confident and completely wrong time on a mirror. Leaving it
 * invalid makes the clock widget show its placeholder instead.
 */
void sntp_time_fill(ml_time *out);

bool sntp_time_is_synced(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_SNTP_TIME_H */
