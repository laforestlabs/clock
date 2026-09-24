/*
 * seats.c - the link-to-player table. See seats.h for what it is for.
 */
#include "mirror/seats.h"

#include <string.h>

static uint16_t player_held_by(const ml_seat_table *t, uint16_t key)
{
    for (int i = 0; i < ML_SEATS_MAX; i++) {
        if (t->seat[i].used && t->seat[i].key == key) return t->seat[i].player;
    }
    return 0;
}

void ml_seats_init(ml_seat_table *t, int cap)
{
    if (!t) return;
    memset(t, 0, sizeof(*t));
    if (cap < 1) cap = 1;
    if (cap > ML_SEATS_MAX) cap = ML_SEATS_MAX;
    t->cap = cap;
}

int ml_seats_count(const ml_seat_table *t)
{
    return t ? t->count : 0;
}

uint16_t ml_seats_player(const ml_seat_table *t, uint16_t key)
{
    return t ? player_held_by(t, key) : 0;
}

uint16_t ml_seats_leave(ml_seat_table *t, uint16_t key)
{
    if (!t) return 0;
    for (int i = 0; i < ML_SEATS_MAX; i++) {
        if (!t->seat[i].used || t->seat[i].key != key) continue;
        const uint16_t player = t->seat[i].player;
        t->seat[i].used = false;
        t->seat[i].player = 0;
        t->seat[i].key = 0;
        t->seat[i].rx_us = 0;
        t->count--;
        return player;
    }
    return 0;
}

void ml_seats_touch(ml_seat_table *t, uint16_t key, uint64_t now_us)
{
    if (!t) return;
    for (int i = 0; i < ML_SEATS_MAX; i++) {
        if (t->seat[i].used && t->seat[i].key == key) {
            t->seat[i].rx_us = now_us;
            return;
        }
    }
}

void ml_seats_touch_all(ml_seat_table *t, uint64_t now_us)
{
    if (!t) return;
    for (int i = 0; i < ML_SEATS_MAX; i++) {
        if (t->seat[i].used) t->seat[i].rx_us = now_us;
    }
}

uint16_t ml_seats_join(ml_seat_table *t, uint16_t key, uint64_t now_us)
{
    if (!t) return 0;
    if (player_held_by(t, key) != 0) return 0;
    if (t->count >= t->cap) return 0;

    /* The lowest player id no occupied seat holds: a seat that left gives its
     * id back, and the next joiner takes it rather than a new one. */
    uint16_t player = 0;
    for (uint16_t p = 1; p <= (uint16_t)t->cap; p++) {
        bool taken = false;
        for (int i = 0; i < ML_SEATS_MAX; i++) {
            if (t->seat[i].used && t->seat[i].player == p) { taken = true; break; }
        }
        if (!taken) { player = p; break; }
    }
    if (player == 0) return 0;

    for (int i = 0; i < ML_SEATS_MAX; i++) {
        if (t->seat[i].used) continue;
        t->seat[i].used = true;
        t->seat[i].key = key;
        t->seat[i].player = player;
        t->seat[i].rx_us = now_us;
        t->count++;
        return player;
    }
    return 0;
}

bool ml_seats_any_silent(const ml_seat_table *t, uint64_t now_us,
                         uint64_t timeout_us)
{
    if (!t) return false;
    for (int i = 0; i < ML_SEATS_MAX; i++) {
        if (!t->seat[i].used) continue;
        /* A clock that stepped backwards is not evidence of a silent seat. */
        if (now_us >= t->seat[i].rx_us &&
            now_us - t->seat[i].rx_us >= timeout_us) {
            return true;
        }
    }
    return false;
}
