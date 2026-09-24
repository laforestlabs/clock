/*
 * seats_test.c - the link-to-player table.
 *
 * The firmware's session glue drives this table with its NimBLE connection
 * handles, so the rules a two-phone round depends on are pinned here rather
 * than only on a board with two phones in hand: join order decides player
 * ids, a freed id is reused by the next joiner, and one quiet seat is enough
 * to report the table silent.
 */
#include <stdint.h>
#include <stdio.h>

#include "mirror/seats.h"

static int failures;

#define CHECK(cond, ...) do {                                     \
    if (cond) { printf("ok:   "); }                               \
    else { failures++; printf("FAIL: "); }                        \
    printf(__VA_ARGS__);                                          \
    printf("\n");                                                 \
} while (0)

int main(void)
{
    ml_seat_table t;

    /* A capacity is clamped into the array: 0 seats nobody, > 8 overflows. */
    ml_seats_init(&t, 0);
    CHECK(t.cap == 1, "capacity 0 clamps up to 1");
    ml_seats_init(&t, 99);
    CHECK(t.cap == ML_SEATS_MAX, "capacity past the array clamps down");

    ml_seats_init(&t, 2);
    CHECK(ml_seats_count(&t) == 0, "a fresh table holds nobody");
    CHECK(!ml_seats_any_silent(&t, 1000000, 500000),
          "an empty table is never silent");
    CHECK(ml_seats_player(&t, 0) == 0, "an unknown key holds no seat");

    /* Join order decides player id, and a handle of 0 is a real handle. */
    CHECK(ml_seats_join(&t, 0, 1000) == 1, "the first joiner is player 1");
    CHECK(ml_seats_join(&t, 7, 1000) == 2, "the second joiner is player 2");
    CHECK(ml_seats_count(&t) == 2, "two joins fill two seats");
    CHECK(ml_seats_player(&t, 0) == 1, "the zero-handle link holds player 1");
    CHECK(ml_seats_player(&t, 7) == 2, "the other link holds player 2");
    CHECK(ml_seats_player(&t, 9) == 0, "a link that never joined holds nothing");

    /* Full, or already seated: both answer 0, neither disturbs the table. */
    CHECK(ml_seats_join(&t, 8, 1000) == 0, "a third join on a two-seat table is refused");
    CHECK(ml_seats_count(&t) == 2, "the refused join left the table alone");
    CHECK(ml_seats_join(&t, 7, 9999) == 0, "re-joining an already seated key is refused");
    CHECK(ml_seats_player(&t, 7) == 2, "and its seat is intact");
    CHECK(ml_seats_count(&t) == 2, "still two seats");

    /* Leaving hands the id back, and leaving twice is harmless. */
    CHECK(ml_seats_leave(&t, 0) == 1, "leaving player 1 returns its id");
    CHECK(ml_seats_count(&t) == 1, "one seat left");
    CHECK(ml_seats_player(&t, 0) == 0, "the vacated key holds nothing");
    CHECK(ml_seats_leave(&t, 0) == 0, "leaving again returns 0");
    CHECK(ml_seats_join(&t, 5, 1000) == 1, "the next joiner reuses the lowest free id");
    CHECK(ml_seats_player(&t, 7) == 2, "the other seat was not disturbed");
    CHECK(ml_seats_leave(&t, 5) == 1 && ml_seats_leave(&t, 7) == 2,
          "both remaining ids come back on leave");

    /* Silence is per seat: touching one clears only that one. */
    ml_seats_init(&t, 2);
    ml_seats_join(&t, 1, 1000);
    ml_seats_join(&t, 2, 1000);
    CHECK(!ml_seats_any_silent(&t, 1499, 500), "just inside the window is not silent");
    CHECK(ml_seats_any_silent(&t, 1500, 500), "exactly the timeout is silent");
    ml_seats_touch(&t, 1, 1500);
    CHECK(ml_seats_any_silent(&t, 1500, 500), "touching one seat leaves the other silent");
    ml_seats_touch(&t, 2, 1500);
    CHECK(!ml_seats_any_silent(&t, 1500, 500), "touching both clears it");
    ml_seats_touch(&t, 42, 1500);
    CHECK(!ml_seats_any_silent(&t, 1500, 500), "touching an unknown key changes nothing");

    ml_seats_touch_all(&t, 2000);
    CHECK(!ml_seats_any_silent(&t, 2499, 500), "touch_all refreshed every seat");
    CHECK(ml_seats_any_silent(&t, 2500, 500), "and they go silent together again");

    /* A clock that steps backwards is not evidence of silence. */
    ml_seats_touch_all(&t, 5000);
    CHECK(!ml_seats_any_silent(&t, 4000, 500), "an earlier now is not a silent seat");

    if (failures != 0) {
        printf("FAIL %d\n", failures);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
