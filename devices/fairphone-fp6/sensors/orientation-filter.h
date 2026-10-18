/* SPDX-License-Identifier: GPL-3.0-or-later
 * FP6 sensor-side rotation policy, using AOSP Android 16 AccelSensorJudge's
 * thresholds and timing. This implements the policy on IIO coordinates;
 * Android's touchscreen/app/rotation-resolver policy is outside this daemon.
 * Reference: https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r4/services/core/java/com/android/server/wm/WindowOrientationListener.java
 */
#ifndef FP6_ORIENTATION_FILTER_H
#define FP6_ORIENTATION_FILTER_H

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define FP6_TILT_HISTORY 200
#define FP6_DEGREES (180.0 / 3.14159265358979323846)
#define FP6_MS(value) (INT64_C(1000) * (value))

typedef struct {
    bool initialized, overhead;
    double x, y, z;
    int candidate;
    int64_t last_sample, candidate_since, last_flat, last_swing, last_acceleration;
    unsigned int history_next, history_count;
    struct { int tilt; int64_t time; } history[FP6_TILT_HISTORY];
} Fp6OrientationFilter;

static bool
fp6_angle_acceptable(int current, int candidate, int angle)
{
    /* AOSP uses integer degrees and 45 / 2, hence 67 and 23 degrees. */
    int distance = (angle - current * 90 + 540) % 360 - 180;
    int step = (candidate - current + 4) % 4;
    switch (step) {
    case 0: return abs(distance) <= 45 - 45 / 2;
    case 1: return distance >= 45 + 45 / 2;
    case 3: return distance <= -(45 + 45 / 2);
    default: return true;
    }
}

/* Return rotation 0/1/2/3, or -1 to keep the current display orientation.
 * Input is mounted IIO acceleration in m/s² (+X left-up, -Y upright, +Z face-up).
 * now is monotonic microseconds, independent of wall clock adjustments.
 */
static int
fp6_orientation_update(Fp6OrientationFilter *f, int current,
                       double x, double y, double z, int64_t now)
{
    static const int maximum_tilt[] = { 70, 65, 60, 65 };
    if (!isfinite(x) || !isfinite(y) || !isfinite(z)) {
        f->initialized = false;
        return -1;
    }
    if (!f->initialized || now < f->last_sample
        || now - f->last_sample > FP6_MS(1000)
        || (x == 0 && y == 0 && z == 0)) {
        memset(f, 0, sizeof(*f));
        f->initialized = true;
        f->candidate = -1;
        f->last_flat = f->last_swing = f->last_acceleration = INT64_MIN / 2;
        f->x = x;
        f->y = y;
        f->z = z;
        f->last_sample = now;
        return -1;
    }

    double elapsed = (double)(now - f->last_sample);
    double alpha = elapsed / (FP6_MS(200) + elapsed);
    f->last_sample = now;
    f->x += alpha * (x - f->x);
    f->y += alpha * (y - f->y);
    f->z += alpha * (z - f->z);

    double magnitude = sqrt(f->x * f->x + f->y * f->y + f->z * f->z);
    if (magnitude < 1) {
        f->candidate = -1;
        return -1;
    }
    if (magnitude < 9.80665 - 4 || magnitude > 9.80665 + 4)
        f->last_acceleration = now;

    /* floor(a + .5) matches Java Math.round, including negative half degrees. */
    int tilt = (int)floor(asin(fmax(-1, fmin(1, f->z / magnitude))) * FP6_DEGREES + .5);
    f->history[f->history_next].tilt = tilt;
    f->history[f->history_next].time = now;
    f->history_next = (f->history_next + 1) % FP6_TILT_HISTORY;
    if (f->history_count < FP6_TILT_HISTORY)
        f->history_count++;

    bool flat = true;
    for (unsigned int n = 0; n < f->history_count; n++) {
        unsigned int i = (f->history_next + FP6_TILT_HISTORY - 1 - n) % FP6_TILT_HISTORY;
        int64_t age = now - f->history[i].time;
        if (f->history[i].tilt < 80)
            flat = false;
        if (flat && age >= FP6_MS(1000))
            f->last_flat = now;
        if (age <= FP6_MS(300) && tilt - f->history[i].tilt >= 20)
            f->last_swing = now;
    }

    if (tilt <= -40)
        f->overhead = true;
    else if (tilt >= -15)
        f->overhead = false;

    int angle = (int)floor(atan2(f->x, -f->y) * FP6_DEGREES + .5);
    if (angle < 0)
        angle += 360;
    int candidate = ((angle + 45) / 90) % 4;
    if (current < 0 || current > 3)
        current = 0; /* The FP6 session starts in portrait. */

    if (f->overhead || abs(tilt) > 80 || tilt < -25
        || tilt > maximum_tilt[candidate]
        || !fp6_angle_acceptable(current, candidate, angle)) {
        f->candidate = -1;
        return -1;
    }
    if (candidate != f->candidate) {
        f->candidate = candidate;
        f->candidate_since = now;
    }
    if (now < f->candidate_since + FP6_MS(40)
        || now < f->last_flat + FP6_MS(500)
        || now < f->last_swing + FP6_MS(300)
        || now < f->last_acceleration + FP6_MS(500))
        return -1;

    return candidate;
}

#endif
