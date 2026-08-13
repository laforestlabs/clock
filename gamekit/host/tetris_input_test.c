/*
 * tetris_input_test.c - regression test for the Down (soft drop) contract.
 *
 * Two bugs this pins down:
 *
 *  1. Down must accelerate the fall, not hard-drop. The old code dropped the
 *     piece to the floor in the same tick, and because the phone streams the
 *     full held state every frame, a held Down re-triggered the drop every
 *     frame, locking several pieces before the player could release.
 *
 *  2. The soft drop must stop at the lock: the next piece only accelerates
 *     again after the player releases Down and holds it once more. Held-down
 *     frames that cross a lock must not re-engage.
 *
 * Observable: on a 64x32 panel the field is the 32-wide center (origin x=16,
 * frame at columns 15 and 48, row 31). Every piece is 4 lit cells; a locked
 * piece adds 4 settled cells. The score text sits at (1,1), outside the
 * field, so counting lit cells inside the field isolates the pieces.
 *
 * Script: no input for 100 ticks (piece falls 5 rows by gravity), Down held
 * for 10 ticks (soft drop, 10 rows, no lock), released for 10 ticks, then
 * Down held for 60 ticks (piece reaches the floor and locks; the next piece
 * must NOT accelerate while Down stays held), then release once and hold
 * again (the soft drop must re-engage and lock the second piece). Expected
 * cell counts: 4, 4, 4, 8, 12.
 */
#include <stdint.h>
#include <stdio.h>

#include "game_ffi.h"

#define PANEL_W 64
#define PANEL_H 32
#define FIELD_X 16   /* (panel_w - field_w) / 2, field_w = min(32, panel_w) */
#define FIELD_Y 0
#define FIELD_W 32
#define FIELD_H 32

/* Count lit cells inside the field rect, excluding the dim frame: the frame
 * is the only gray on the panel (every piece colour and the settled stack
 * have unequal channels), and the black background is zero. The score text
 * sits at (1,1), outside the field, and the next-piece preview in the right
 * margin is beyond x=48. */
static int lit_cells(ml_game_session *s)
{
    const uint8_t *rgba = ml_game_render_rgba(s);
    if (!rgba) return -1;

    int count = 0;
    for (int y = FIELD_Y; y < FIELD_Y + FIELD_H; y++) {
        for (int x = FIELD_X; x < FIELD_X + FIELD_W; x++) {
            const uint8_t *p = rgba + ((size_t)y * PANEL_W + x) * 4;
            if (p[0] || p[1] || p[2]) {
                /* frame gray is r == g == b; any piece cell is not */
                if (!(p[0] == p[1] && p[1] == p[2])) count++;
            }
        }
    }
    return count;
}

static void hold_down(ml_game_session *s, int steps)
{
    for (int t = 0; t < steps; t++) {
        ml_game_button(s, 1, 1, 1);  /* Down held */
        ml_game_step(s, 25);         /* tetris tick_ms is 25: one tick */
    }
}

static void release_down(ml_game_session *s, int steps)
{
    for (int t = 0; t < steps; t++) {
        ml_game_button(s, 1, 1, 0);  /* Down released */
        ml_game_step(s, 25);
    }
}

int main(void)
{
    ml_game_session *s = ml_game_open("tetris", PANEL_W, PANEL_H, 1, 1);
    if (!s) { fprintf(stderr, "open failed\n"); return 1; }

    int fail = 0;

    /* 1. 100 gravity ticks, no input: one falling piece, 4 cells. */
    for (int t = 0; t < 100; t++) ml_game_step(s, 25);
    int idle = lit_cells(s);
    printf("idle x100:        cells=%d (expect 4)\n", idle);
    if (idle != 4) fail = 1;

    /* 2. Down held for 10 ticks: soft drop 10 rows, still no lock. The
     * hard-drop bug locks here and the count explodes. */
    hold_down(s, 10);
    int soft = lit_cells(s);
    printf("soft drop x10:    cells=%d (expect 4, bug: many)\n", soft);
    if (soft != 4) fail = 1;

    /* 3. Released for 10 ticks: gravity barely moves, still 4 cells. */
    release_down(s, 10);
    int released = lit_cells(s);
    printf("released x10:     cells=%d (expect 4)\n", released);
    if (released != 4) fail = 1;

    /* 4. Down held for 60 ticks: the piece reaches the floor and locks
     * (4 settled cells, all inside the field), the next piece spawns
     * (4 falling) and the held Down must not re-engage it. The re-engage
     * bug drops the second piece the same way and locks it too (12 cells).
     * Without the bug the second piece sits at py=2 by gravity: 8 cells. */
    hold_down(s, 60);
    int held_through_lock = lit_cells(s);
    printf("held thru lock:   cells=%d (expect 8, bug: 12)\n",
           held_through_lock);
    if (held_through_lock != 8) fail = 1;

    /* 5. Release once, hold again: the soft drop must re-engage for the new
     * piece, which falls to the floor and locks (8 settled + 4 falling).
     * A broken re-arm leaves the piece drifting at gravity speed: 8 cells. */
    release_down(s, 1);
    hold_down(s, 30);
    int rearmed = lit_cells(s);
    printf("re-armed hold:    cells=%d (expect 12, bug: 8)\n", rearmed);
    if (rearmed != 12) fail = 1;

    ml_game_close(s);

    if (fail) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
