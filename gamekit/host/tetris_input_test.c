/*
 * tetris_input_test.c - regression test for the Tetris rotation and Down
 * (soft drop) contracts.
 *
 * Three bugs this pins down:
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
 *  3. Up must rotate once per press, not once per event. The same full-state
 *     stream delivers a run of Up=1 packets while the button is held (and a
 *     keyboard repeats the key), and each one used to spin the piece again.
 *     Only the 0->1 edge rotates; a release re-arms the next press.
 *
 *  4. Down must lock the piece's column while it is held. A direction key
 *     arriving with Down used to walk the piece sideways on its way down, so
 *     the drop landed a column or two from where the player aimed it.
 *
 * Observable: the field is a fixed 10x16 logical board drawn at 2 pixels a
 * cell, so on a 64x32 panel it is 20 pixels wide (origin x=22) and the full
 * panel height, with the frame at columns 21 and 42. Every piece is 4 lit
 * cells; a locked piece adds 4 settled cells. The score text sits in the left
 * margin, outside the field, so counting lit cells inside the field isolates
 * the pieces. The field also holds the falling piece's landing preview, which
 * is a third of the piece's colour and so is excluded by brightness - a
 * channel past 30 in the gamma-corrected frame - rather than by colour, the
 * way the grey frame is.
 *
 * Script: no input for 100 ticks (piece falls 5 rows by gravity), Down held
 * for 5 ticks (soft drop, 5 rows to logical y=10, no lock on the 16-row
 * field), released for 10 ticks, then Down held for 60 ticks (piece reaches
 * the floor and locks; the next piece must NOT accelerate while Down stays
 * held), then release once and hold again (the soft drop must re-engage and
 * lock the second piece). Expected cell counts: 4, 4, 4, 8, 12.
 *
 * The rotation cases run on their own sessions, opened with seed 2, which
 * deals the T piece: all four of its rotations are distinct, so a rotation
 * that silently did nothing cannot pass. Seed 1 deals the rotation-invariant
 * O piece, which is why the soft-drop sessions above cannot show it.
 * Nothing is stepped between the Up events, so gravity and the score
 * animation cannot account for any difference.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "game_ffi.h"

#define PANEL_W 64
#define PANEL_H 32
#define CELL_PX 2    /* one board cell is 2x2 physical pixels */
#define FIELD_X 22   /* (panel_w - 10*CELL_PX) / 2 */
#define FIELD_Y 0    /* (panel_h - 16*CELL_PX) / 2 */
#define FIELD_W 20   /* TETRIS_BW * CELL_PX */
#define FIELD_H 32   /* TETRIS_BH * CELL_PX */

/* Count lit logical cells inside the field rect, one sample per cell at its
 * top-left pixel, excluding the dim frame: the frame is the only gray on the
 * panel (every piece colour and the settled stack have unequal channels), and
 * the black background is zero. The score text sits in the left margin,
 * outside the field, and the next-piece preview in the right one is past
 * x=42. A cell is the piece (or the settled stack) when a channel is past 30
 * in the rendered, gamma-corrected frame: the landing preview is a third of
 * the piece's colour, so it tops out at 20, while the dimmest thing the counts
 * must include, the settled stack, is 41. The grey frame is excluded by its
 * equal channels. */
static int lit_cells(ml_game_session *s)
{
    const uint8_t *rgba = ml_game_render_rgba(s);
    if (!rgba) return -1;

    int count = 0;
    for (int y = FIELD_Y; y < FIELD_Y + FIELD_H; y += CELL_PX) {
        for (int x = FIELD_X; x < FIELD_X + FIELD_W; x += CELL_PX) {
            const uint8_t *p = rgba + ((size_t)y * PANEL_W + x) * 4;
            if ((p[0] > 30 || p[1] > 30 || p[2] > 30) &&
                !(p[0] == p[1] && p[1] == p[2])) count++;
        }
    }
    return count;
}

static void hold_down(ml_game_session *s, int steps)
{
    for (int t = 0; t < steps; t++) {
        ml_game_input(s, 1, 1, 1);  /* Down held */
        ml_game_step(s, 25);         /* tetris tick_ms is 25: one tick */
    }
}

static void release_down(ml_game_session *s, int steps)
{
    for (int t = 0; t < steps; t++) {
        ml_game_input(s, 1, 1, 0);  /* Down released */
        ml_game_step(s, 25);
    }
}

/* One tick of a phone's full-state stream with Down held and a direction key
 * at the given state. Tetris' controls are Up=0, Down=1, Left=2, Right=3. */
static void tick_down_steer(ml_game_session *s, int left, int right)
{
    ml_game_input(s, 1, 1, 1);      /* Down held */
    ml_game_input(s, 1, 2, left);   /* Left */
    ml_game_input(s, 1, 3, right);  /* Right */
    ml_game_step(s, 25);
}

/* One tick with Down up and a direction key at the given state. */
static void tick_steer(ml_game_session *s, int left, int right)
{
    ml_game_input(s, 1, 1, 0);      /* Down up */
    ml_game_input(s, 1, 2, left);   /* Left */
    ml_game_input(s, 1, 3, right);  /* Right */
    ml_game_step(s, 25);
}

/* Byte-compare the field rect of two sessions. The two render buffers are
 * session-owned, and the rect excludes the score text at (1,1) and the
 * next-piece preview in the right margin, so only the piece's cells can
 * differ. Comparing rendered panel pixels keeps the assertion on observable
 * output rather than on the session's private held state. */
static int same_field(ml_game_session *a, ml_game_session *b)
{
    const uint8_t *ra = ml_game_render_rgba(a);
    const uint8_t *rb = ml_game_render_rgba(b);
    if (!ra || !rb) return 0;

    for (int y = FIELD_Y; y < FIELD_Y + FIELD_H; y++) {
        const uint8_t *pa = ra + ((size_t)y * PANEL_W + FIELD_X) * 4;
        const uint8_t *pb = rb + ((size_t)y * PANEL_W + FIELD_X) * 4;
        if (memcmp(pa, pb, (size_t)FIELD_W * 4) != 0) return 0;
    }
    return 1;
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

    /* 2. Down held for 5 ticks: soft drop 5 rows to logical y=10, still no
     * lock on the 16-row field. The hard-drop bug locks here and the count
     * explodes. */
    hold_down(s, 5);
    int soft = lit_cells(s);
    printf("soft drop x5:     cells=%d (expect 4, bug: many)\n", soft);
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

    /* 6. Down locks the piece horizontally. Three sessions get the same five
     * ticks of a held Down; one also holds Left and one holds Right. All
     * three fields must be identical, because a held drop commits the piece to
     * its column. The walk session is the control: the same Left press with
     * Down up must move the piece, or the lock assertions would pass for a
     * game that had simply stopped listening to Left. */
    ml_game_session *ldrop = ml_game_open("tetris", PANEL_W, PANEL_H, 1, 1);
    ml_game_session *lleft = ml_game_open("tetris", PANEL_W, PANEL_H, 1, 1);
    ml_game_session *lright = ml_game_open("tetris", PANEL_W, PANEL_H, 1, 1);
    ml_game_session *lwalk = ml_game_open("tetris", PANEL_W, PANEL_H, 1, 1);
    ml_game_session *lstill = ml_game_open("tetris", PANEL_W, PANEL_H, 1, 1);
    if (!ldrop || !lleft || !lright || !lwalk || !lstill) {
        fprintf(stderr, "open failed\n");
        return 1;
    }

    for (int t = 0; t < 5; t++) {
        tick_down_steer(ldrop, 0, 0);
        tick_down_steer(lleft, 1, 0);
        tick_down_steer(lright, 0, 1);
        tick_steer(lwalk, 1, 0);
        tick_steer(lstill, 0, 0);
    }

    int lock_left = same_field(ldrop, lleft);
    int lock_right = same_field(ldrop, lright);
    int walk_differs = !same_field(lstill, lwalk);
    printf("Down+Left:        ==Down only=%d (expect 1)\n", lock_left);
    printf("Down+Right:       ==Down only=%d (expect 1)\n", lock_right);
    printf("Left, Down up:    field moved=%d (expect 1)\n", walk_differs);
    if (!lock_left || !lock_right || !walk_differs) fail = 1;

    /* 7. The lock ends with the press. A Left still held when Down comes up
     * lands on the next tick, so the held key was ignored, not swallowed. */
    tick_steer(lleft, 1, 0);
    tick_steer(ldrop, 0, 0);
    int queued = !same_field(ldrop, lleft);
    printf("Left after drop:  field moved=%d (expect 1)\n", queued);
    if (!queued) fail = 1;

    ml_game_close(ldrop);
    ml_game_close(lleft);
    ml_game_close(lright);
    ml_game_close(lwalk);
    ml_game_close(lstill);

    /* 8. Up rotates once per press. Three Up=1 packets with no release in
     * between are one press, exactly as the phone's per-frame full-state
     * stream delivers them; the field must match a session that received a
     * single Up=1. The frozen session pins the "rotated at all" half: if the
     * edge handling accidentally swallowed every press, the held session
     * would match it and the first assertion would pass vacuously. */
    ml_game_session *up1   = ml_game_open("tetris", PANEL_W, PANEL_H, 2, 1);
    ml_game_session *uprep = ml_game_open("tetris", PANEL_W, PANEL_H, 2, 1);
    ml_game_session *up2   = ml_game_open("tetris", PANEL_W, PANEL_H, 2, 1);
    ml_game_session *up0   = ml_game_open("tetris", PANEL_W, PANEL_H, 2, 1);
    if (!up1 || !uprep || !up2 || !up0) {
        fprintf(stderr, "open failed\n");
        return 1;
    }

    ml_game_input(up1, 1, 0, 1);   /* one press, no step */
    ml_game_input(uprep, 1, 0, 1); /* held: three packets, no release */
    ml_game_input(uprep, 1, 0, 1);
    ml_game_input(uprep, 1, 0, 1);

    int rotated = !same_field(up0, up1);
    int held_once = same_field(up1, uprep);
    printf("one Up press:     field moved=%d (expect 1)\n", rotated);
    printf("held Up x3:       ==one press=%d (expect 1, bug: 0)\n", held_once);
    if (!rotated || !held_once) fail = 1;

    /* 9. Releasing re-arms the next press: the held session rotates a second
     * time, matching a clean two-press reference, and no longer matches the
     * one-rotation frame (T's four rotations are all distinct). A session
     * that ignored the release stays at one rotation and matches nothing. */
    ml_game_input(uprep, 1, 0, 0);  /* release */
    ml_game_input(uprep, 1, 0, 1);  /* press again: second rotation */
    ml_game_input(up2, 1, 0, 1);    /* clean two-press reference */
    ml_game_input(up2, 1, 0, 0);
    ml_game_input(up2, 1, 0, 1);

    int two_matches = same_field(uprep, up2);
    int two_differs = !same_field(up1, uprep);
    printf("release+press:    ==two presses=%d (expect 1)\n", two_matches);
    printf("one vs two:       fields differ=%d (expect 1)\n", two_differs);
    if (!two_matches || !two_differs) fail = 1;

    ml_game_close(up1);
    ml_game_close(uprep);
    ml_game_close(up2);
    ml_game_close(up0);

    if (fail) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
