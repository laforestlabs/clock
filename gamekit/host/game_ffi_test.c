/*
 * game_ffi_test.c - prove the gamekit FFI layer works end to end.
 *
 * Exercises the same calls Dart makes: open, step, button, render. Runs the
 * rally game for 90 ticks, renders a frame, and prints an FNV hash and a
 * small ASCII preview. This is the proof that the symbols Dart binds to do
 * what the game screen expects.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "game_ffi.h"

static uint32_t fnv1a(const uint8_t *p, size_t n)
{
    uint32_t h = 0x811c9dc5u;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 0x01000193u; }
    return h;
}

static void ascii(const uint8_t *rgb, int w, int h)
{
    for (int y = 0; y < h && y < 20; y++) {
        for (int x = 0; x < w; x++) {
            const uint8_t *p = rgb + ((size_t)y * w + x) * 4;
            int lum = (p[0] * 30 + p[1] * 59 + p[2] * 11) / 100;
            const char *c = lum > 160 ? "██" : lum > 80 ? "▓▓" : lum > 24 ? "░░" : "  ";
            fputs(c, stdout);
        }
        fputc('\n', stdout);
    }
}

int main(void)
{
    int ngames = ml_game_count();
    printf("games compiled in: %d\n", ngames);
    for (int i = 0; i < ngames; i++)
        printf("  [%d] %s (%s), max %d players, %d controls: ",
               i, ml_game_name(i), ml_game_id(i),
               ml_game_max_players(i), ml_game_control_count(i));
    for (int i = 0; i < ngames; i++)
        for (int c = 0; c < ml_game_control_count(i); c++)
            printf("%s ", ml_game_control_label(i, c));
    printf("\n");

    /* Open rally at 64x32, 1 player, seed 1. */
    ml_game_session *s = ml_game_open("rally", 64, 32, 1, 1);
    if (!s) { fprintf(stderr, "ml_game_open failed\n"); return 1; }

    printf("session: %dx%d\n", ml_game_width(s), ml_game_height(s));

    /* Feed a few button presses to exercise the input path. */
    ml_game_button(s, 1, 1, 1);  /* player 1, code 1 (Down), pressed */
    for (int t = 0; t < 30; t++) ml_game_step(s, 33);
    ml_game_button(s, 1, 1, 0);  /* release */
    ml_game_button(s, 1, 0, 1);  /* code 0 (Up), pressed */
    for (int t = 0; t < 30; t++) ml_game_step(s, 33);
    ml_game_button(s, 1, 0, 0);  /* release */
    for (int t = 0; t < 30; t++) ml_game_step(s, 33);

    printf("tick after 90 steps: %d\n", ml_game_tick(s));

    /* Render and hash. */
    const uint8_t *rgba = ml_game_render_rgba(s);
    int size = ml_game_rgba_size(s);
    if (!rgba || size <= 0) { fprintf(stderr, "render failed\n"); return 1; }

    uint32_t hash = fnv1a(rgba, (size_t)size);
    printf("rgba size: %d bytes\n", size);
    printf("frame hash: %08x\n", hash);
    printf("--- ASCII preview ---\n");
    ascii(rgba, ml_game_width(s), ml_game_height(s));

    ml_game_close(s);
    printf("OK\n");
    return 0;
}