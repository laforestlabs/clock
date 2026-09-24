/*
 * seats.h - who is playing: link-to-player seating, shared by firmware and host.
 *
 * A session is driven by controllers, and on the device a controller is a BLE
 * link. Which link owns which player, and whether a seated player has gone
 * quiet, are policy the firmware's session glue needs but cannot host-test
 * (game_runner.c is ESP-IDF-only), so the pure part lives here instead.
 *
 * The caller supplies the clock and the key, so the firmware's NimBLE
 * connection table and a host test drive the same code. A key is opaque: the
 * firmware passes its connection handle, which may legitimately be 0, so "this
 * seat is taken" is the used flag and never a zero key.
 *
 * The table is deliberately small: it answers "who is in, and since when" and
 * nothing else. A caller that must act on every occupied seat (releasing each
 * player's controls on pause, refreshing every receipt stamp on resume) walks
 * the public seat array rather than growing this API per use.
 */
#ifndef MIRROR_SEATS_H
#define MIRROR_SEATS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The most seats any table can hold. */
#define ML_SEATS_MAX 8

/* One occupied seat. `player` is the 1-based player id the game is told about,
 * `rx_us` the last time this seat proved it was there. */
typedef struct {
    bool     used;
    uint16_t key;
    uint16_t player;
    uint64_t rx_us;
} ml_seat;

typedef struct {
    ml_seat seat[ML_SEATS_MAX];
    int     cap;      /* seats that may be filled at once, 1..ML_SEATS_MAX */
    int     count;    /* seats currently filled */
} ml_seat_table;

/* Empty the table and set its capacity. cap is clamped to 1..ML_SEATS_MAX, so
 * a caller that passes a game's own max_players cannot leave a table that
 * seats nobody or overflows its array. */
void     ml_seats_init(ml_seat_table *t, int cap);

/* Seats currently filled. */
int      ml_seats_count(const ml_seat_table *t);

/* The player id `key` holds, or 0 when that key holds no seat. */
uint16_t ml_seats_player(const ml_seat_table *t, uint16_t key);

/* Give up the seat `key` holds and return the player id it had, or 0 when the
 * key held none. The freed id is the lowest free id again, so a later join
 * reuses it. */
uint16_t ml_seats_leave(ml_seat_table *t, uint16_t key);

/* Mark `key` as heard from. Unknown keys are ignored: only a seated link's
 * stamp is worth keeping. */
void     ml_seats_touch(ml_seat_table *t, uint16_t key, uint64_t now_us);

/* Mark every occupied seat as heard from. Used when the whole round is
 * resumed and every seat's silence from the paused period is forgiven. */
void     ml_seats_touch_all(ml_seat_table *t, uint64_t now_us);

/* Seat `key` at the lowest free player id (1-based) and return that id, or 0
 * when the table is full or the key already holds a seat (ask
 * ml_seats_player to tell those apart). */
uint16_t ml_seats_join(ml_seat_table *t, uint16_t key, uint64_t now_us);

/* Whether any occupied seat has been silent for at least timeout_us. An empty
 * table is never silent: nobody has failed to report in. */
bool     ml_seats_any_silent(const ml_seat_table *t, uint64_t now_us,
                             uint64_t timeout_us);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_SEATS_H */
