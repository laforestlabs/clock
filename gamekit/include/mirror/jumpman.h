/*
 * jumpman.h - the campaign surface Jumpman exposes to its hosts.
 *
 * The game itself signs the ml_game_vt contract in game.h, and nothing here
 * changes that: the vtable still runs one session of one game. What this header
 * adds is the bit a Jumpman run has and the other games do not - a campaign of
 * three built-in courses with persistent unlocks - and it is deliberately the
 * only thing a host needs to know about it.
 *
 * The state pointer is the one the runtime owns (ml_host_state); the host never
 * sees inside it. Courses are one-based, 1..ML_JUMPMAN_COURSES, and the unlocked
 * count is trusted persistent storage the host supplies - never a player's
 * selection, which is why the game treats a course above it as locked.
 *
 * A session whose level was handed in at run time (the level editor's playtest)
 * is not a campaign at all: it is one level, its course reads 0, and it never
 * unlocks anything. ml_jumpman_start_course is how a host leaves that mode.
 */
#ifndef MIRROR_JUMPMAN_H
#define MIRROR_JUMPMAN_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The built-in courses, in play order: 1 Original, 2 Pipe Garden, 3 Koopa
 * Quarry. Course N unlocks course N+1 the moment its flag is reached. */
#define ML_JUMPMAN_COURSES 3

/*
 * Begin a fresh run of a built-in course: three lives, score zero, no
 * checkpoint, and the course's level loaded. course and unlocked are one-based;
 * unlocked is the highest course the host's persistent storage has granted and
 * must be at least course. Returns false - leaving the state exactly as it was -
 * for a course or an unlocked count outside 1..ML_JUMPMAN_COURSES, or a course
 * above unlocked. Call it on a freshly opened session, before the first step;
 * it selects the built-in campaign even when an editor level override was set.
 */
bool ml_jumpman_start_course(void *state, int course, int unlocked);

/* The built-in course being played, 1..ML_JUMPMAN_COURSES, or 0 when the
 * session is playing a level handed in at run time (or has no state). */
int ml_jumpman_course(const void *state);

/*
 * The highest built-in course unlocked, 1..ML_JUMPMAN_COURSES, or 0 for a
 * session that is not a campaign. It is the host's value until the player
 * reaches a course's flag, at which point it rises immediately - mid-run,
 * before any game over - so the host can poll it after each step and persist
 * the increase.
 */
int ml_jumpman_unlocked(const void *state);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_JUMPMAN_H */
