/*
 * held_input_test.c - regression test for the held-button input contract.
 *
 * Hosts (the Flutter game screen, the CLI) feed the full held state every
 * frame, Up (code 0) first, then Down (code 1). rally_input must accumulate
 * held state per button: an earlier version zeroed paddle_v on any released
 * event, so the Down-released event erased the Up velocity each frame and
 * the paddle only ever moved down.
 *
 * Measures the left paddle's top y by scanning column x=1 for the bright
 * cyan run (the paddle is 8px tall; the ball is a single pixel, so only a
 * run of >= 4 bright pixels counts).
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "game_ffi.h"

static int paddle_top(const uint8_t *rgba, int w, int h)
{
    int run_start = -1, run_len = 0;
    int best_start = -1, best_len = 0;
    for (int y = 0; y < h; y++) {
        const uint8_t *p = rgba + ((size_t)y * w + 1) * 4;
        int bright = (p[1] > 100 && p[2] > 100); /* cyan: strong G and B */
        if (bright) {
            if (run_len == 0) run_start = y;
            run_len++;
        } else {
            if (run_len > best_len) { best_len = run_len; best_start = run_start; }
            run_len = 0;
        }
    }
    if (run_len > best_len) { best_len = run_len; best_start = run_start; }
    return best_len >= 4 ? best_start : -1;
}

int main(void)
{
    ml_game_session *s = ml_game_open("rally", 64, 32, 1, 1);
    if (!s) { fprintf(stderr, "open failed\n"); return 1; }

    printf("start:           top=%2d (expect 12)\n",
           paddle_top(ml_game_render_rgba(s), 64, 32));

    /* Up held for 10 ticks, full state every frame, Up event first. */
    for (int t = 0; t < 10; t++) {
        ml_game_button(s, 1, 0, 1); /* Up held */
        ml_game_button(s, 1, 1, 0); /* Down not held */
        ml_game_step(s, 50);
    }
    int up_top = paddle_top(ml_game_render_rgba(s), 64, 32);
    printf("up held x10:     top=%2d (expect 0; buggy code stays at 12)\n", up_top);

    /* Release Up, hold Down. From y=0 at 2px/tick the paddle needs 12
     * ticks to reach the clamp at 24, so run 15. */
    for (int t = 0; t < 15; t++) {
        ml_game_button(s, 1, 0, 0); /* Up not held */
        ml_game_button(s, 1, 1, 1); /* Down held */
        ml_game_step(s, 50);
    }
    int down_top = paddle_top(ml_game_render_rgba(s), 64, 32);
    printf("down held x15:   top=%2d (expect 24)\n", down_top);

    ml_game_close(s);

    if (up_top != 0 || down_top != 24) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
