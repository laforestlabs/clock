/*
 * mock.h - synthetic model data for designing layouts offline.
 *
 * This lives in the portable core rather than in the desktop app so that the
 * designer, the golden-image tests, and the firmware's self-test all render
 * from byte-identical fixtures. If the mock data lived only in Python, a
 * golden image could pass on the host and mean nothing about the device.
 */
#ifndef MIRROR_MOCK_H
#define MIRROR_MOCK_H

#include "mirror/model.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    /* A normal Wednesday morning: clock synced, weather in, a few events. */
    ML_MOCK_TYPICAL = 0,
    /* Nothing has arrived yet. Exercises every placeholder path, which is what
     * the mirror actually shows for the first few seconds after boot. */
    ML_MOCK_COLD = 1,
    /* Deliberately overlong titles and a full list. Exercises truncation and
     * row overflow, the two things that look fine in design and break on
     * real calendar data. */
    ML_MOCK_OVERFLOW = 2,
    /* Evening, bad weather, empty lists. */
    ML_MOCK_EVENING = 3,

    ML_MOCK_VARIANTS = 4
} ml_mock_variant;

/* Fill m with the named fixture. Unknown variants fall back to ML_MOCK_TYPICAL. */
void ml_model_mock(ml_model *m, int variant);

/* Short name for a variant, for CLI help and the designer's dropdown. */
const char *ml_mock_name(int variant);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_MOCK_H */
