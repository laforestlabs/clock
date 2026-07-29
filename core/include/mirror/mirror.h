/*
 * mirror.h - umbrella header for the portable render core.
 *
 * This library is strict C99 with no platform dependencies: no ESP-IDF, no
 * FreeRTOS, no POSIX beyond the C standard library. It compiles unchanged into
 * the firmware and into a host shared library that the PySide6 designer calls
 * through cffi. Keep it that way. Anything platform-specific belongs in
 * firmware/ or in the designer, not here.
 */
#ifndef MIRROR_H
#define MIRROR_H

#include "mirror/canvas.h"
#include "mirror/color.h"
#include "mirror/font.h"
#include "mirror/layout.h"
#include "mirror/model.h"
#include "mirror/render.h"

#define ML_VERSION_MAJOR 0
#define ML_VERSION_MINOR 1
#define ML_VERSION_PATCH 0
#define ML_VERSION_STR   "0.1.0"

#endif /* MIRROR_H */
