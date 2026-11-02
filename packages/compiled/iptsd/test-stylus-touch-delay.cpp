// SPDX-License-Identifier: GPL-2.0-or-later
#include "stylus-touch-delay.hpp"

#include <cstdlib>
#include <iostream>

using iptsd::apps::daemon::StylusTouchDelay;
using namespace std::chrono_literals;

static void require(const bool condition, const char *message)
{
	if (!condition) {
		std::cerr << message << '\n';
		std::exit(1);
	}
}

int main()
{
	const StylusTouchDelay::TimePoint start {};
	StylusTouchDelay gate;
	require(!gate.blocked(start), "Normal touch must work before any pen is detected");
	gate.update(false, 1000ms, start);
	require(!gate.blocked(start), "An initial proximity-out must not block touch");
	gate.update(true, 1000ms, start);
	require(gate.blocked(start), "Hover must block touch immediately");
	require(gate.blocked(start + 30s), "A stationary hovering pen must keep touch blocked");
	gate.update(false, 1000ms, start + 30s);
	require(gate.blocked(start + 30999ms), "Touch must stay blocked for the full second");
	require(!gate.blocked(start + 31s), "Touch must return at the one-second boundary");
	gate.update(false, 1000ms, start + 32s);
	require(!gate.blocked(start + 32s), "Repeated out reports must not restart the timer");

	gate.update(true, 1000ms, start + 33s);
	gate.update(false, 1000ms, start + 34s);
	gate.update(true, 1000ms, start + 34500ms);
	require(gate.blocked(start + 35s), "Re-entry must cancel the pending release");
	gate.update(false, 1000ms, start + 36s);
	require(gate.blocked(start + 36999ms), "The next exit must start a fresh full second");
	require(!gate.blocked(start + 37s), "Touch must recover after the new delay");

	gate.update(true, 0ms, start + 38s);
	gate.update(false, 0ms, start + 39s);
	require(!gate.blocked(start + 39s), "Zero delay must preserve immediate restoration");
	std::cout << "Stylus touch delay tests passed\n";
}
