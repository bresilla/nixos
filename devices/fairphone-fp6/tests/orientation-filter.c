#include <assert.h>
#include <stdio.h>
#include "fp6-orientation-filter.h"

typedef struct {
    Fp6OrientationFilter filter;
    int rotation;
    int64_t now;
} Phone;

static void
sample(Phone *p, double angle, double tilt, double magnitude, int milliseconds)
{
    double a = angle / FP6_DEGREES, t = tilt / FP6_DEGREES;
    p->now += FP6_MS(milliseconds);
    int result = fp6_orientation_update(&p->filter, p->rotation,
        magnitude * sin(a) * cos(t), -magnitude * cos(a) * cos(t),
        magnitude * sin(t), p->now);
    if (result >= 0)
        p->rotation = result;
}

static void
hold(Phone *p, double angle, double tilt, int milliseconds)
{
    for (int i = 0; i < milliseconds; i += 20)
        sample(p, angle, tilt, 9.80665, 20);
}

static void
test_hysteresis(void)
{
    Phone p = {0};
    hold(&p, 0, 0, 1000);
    hold(&p, 60, 0, 2000);
    assert(p.rotation == 0); /* Modest sideways tilt must not rotate. */
    hold(&p, 66, 0, 2000);
    assert(p.rotation == 0);
    hold(&p, 68, 0, 2000);
    assert(p.rotation == 1);
    hold(&p, 45, 0, 2000);
    assert(p.rotation == 1); /* Different return threshold prevents flapping. */
    hold(&p, 24, 0, 2000);
    assert(p.rotation == 1);
    hold(&p, 22, 0, 2000);
    assert(p.rotation == 0);
    hold(&p, -66, 0, 2000);
    assert(p.rotation == 0);
    hold(&p, -68, 0, 2000);
    assert(p.rotation == 3);
    hold(&p, -45, 0, 2000);
    assert(p.rotation == 3);
    hold(&p, -22, 0, 2000);
    assert(p.rotation == 0);
    for (int rotation = 1; rotation <= 4; rotation++) {
        hold(&p, rotation * 90, 0, 2000);
        assert(p.rotation == rotation % 4);
    }
}

static void
test_tilt_and_overhead(void)
{
    Phone p = {0};
    hold(&p, 0, 0, 1000);
    hold(&p, 0, 72, 2000);
    hold(&p, 90, 72, 2000);
    assert(p.rotation == 0); /* Almost flat: keep portrait. */
    hold(&p, 90, 66, 2000);
    assert(p.rotation == 0);
    hold(&p, 90, 64, 2000);
    assert(p.rotation == 1);
    hold(&p, 0, 69, 2000);
    assert(p.rotation == 0); /* Portrait allows up to 70 degrees. */
    hold(&p, 180, 62, 2000);
    assert(p.rotation == 0); /* Upside down is limited to 60 degrees. */
    hold(&p, 180, 58, 2000);
    assert(p.rotation == 2);

    Phone overhead = {0};
    hold(&overhead, 0, -50, 1000);
    hold(&overhead, 90, -20, 2000);
    assert(overhead.rotation == 0); /* Overhead lock persists until -15. */
    hold(&overhead, 90, -14, 2000);
    assert(overhead.rotation == 1);
}

static void
test_settle_noise_and_acceleration(void)
{
    Phone p = {0};
    sample(&p, 90, 0, 9.80665, 20); /* Prime the low-pass filter. */
    sample(&p, 90, 0, 9.80665, 20); /* Candidate first seen. */
    sample(&p, 90, 0, 9.80665, 20);
    assert(p.rotation == 0);
    sample(&p, 90, 0, 9.80665, 20);
    assert(p.rotation == 1); /* Exactly 40ms settled. */

    Phone noise = {0};
    hold(&noise, 0, 0, 1000);
    for (int i = 0; i < 20; i++) {
        sample(&noise, 90, 0, 9.80665, 20);
        hold(&noise, 0, 0, 200);
        assert(noise.rotation == 0);
    }

    Phone motion = {0};
    for (int i = 0; i < 100; i++)
        sample(&motion, 90, 0, 16, 20);
    assert(motion.rotation == 0);
    int64_t last_acceleration = motion.filter.last_acceleration;
    bool rotated = false;
    for (int i = 0; i < 100; i++) {
        sample(&motion, 90, 0, 9.80665, 20);
        if (motion.filter.last_acceleration > last_acceleration)
            last_acceleration = motion.filter.last_acceleration;
        if (motion.rotation == 1) {
            assert(motion.now >= last_acceleration + FP6_MS(500));
            rotated = true;
            break;
        }
    }
    assert(rotated);
}

static void
test_pickup_and_swing(void)
{
    Phone p = {0};
    hold(&p, 0, 90, 2000);
    assert(p.filter.last_flat > 0);
    int64_t last_flat = p.filter.last_flat;
    for (int i = 0; i < 100; i++) {
        sample(&p, 90, 0, 9.80665, 20);
        if (p.rotation == 1) {
            assert(p.now >= last_flat + FP6_MS(500));
            break;
        }
    }
    assert(p.rotation == 1);

    Phone swing = {0};
    hold(&swing, 0, 0, 1000);
    hold(&swing, 0, 60, 300);
    assert(swing.filter.last_swing > 0);
    for (int i = 0; i < 100; i++) {
        sample(&swing, 90, 60, 9.80665, 20);
        if (swing.rotation == 1) {
            assert(swing.now >= swing.filter.last_swing + FP6_MS(300));
            break;
        }
    }
    assert(swing.rotation == 1);
}

static void
test_sample_gap_and_invalid_data(void)
{
    Phone p = {0};
    hold(&p, 0, 0, 1000);
    sample(&p, 90, 0, 9.80665, 1500);
    assert(p.rotation == 0); /* No stale candidate after resume. */
    sample(&p, 90, 0, 9.80665, 20);
    assert(p.rotation == 0);
    sample(&p, 90, 0, 9.80665, 40);
    assert(p.rotation == 1);
    assert(fp6_orientation_update(&p.filter, 1, NAN, 0, 0, p.now) == -1);
    assert(fp6_orientation_update(&p.filter, 1, 0, 0, 0, p.now + 1) == -1);
    assert(fp6_orientation_update(&p.filter, 1, 0, 0, 0, p.now - 1) == -1);
}

int main(void)
{
    test_hysteresis();
    test_tilt_and_overhead();
    test_settle_noise_and_acceleration();
    test_pickup_and_swing();
    test_sample_gap_and_invalid_data();
    puts("FP6 Android sensor-policy tests passed");
    return 0;
}
