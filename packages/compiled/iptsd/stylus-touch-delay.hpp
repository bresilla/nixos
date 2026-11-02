// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef IPTSD_APPS_DAEMON_STYLUS_TOUCH_DELAY_HPP
#define IPTSD_APPS_DAEMON_STYLUS_TOUCH_DELAY_HPP

#include <chrono>
#include <optional>

namespace iptsd::apps::daemon {

class StylusTouchDelay {
public:
	using Clock = std::chrono::steady_clock;
	using TimePoint = Clock::time_point;

	void update(const bool proximity,
	            const std::chrono::milliseconds delay,
	            const TimePoint now = Clock::now())
	{
		// Only proximity-out starts the timer; repeated out reports must not extend it.
		if (m_proximity && !proximity)
			m_release_at = now + delay;

		m_proximity = proximity;
	}

	[[nodiscard]] bool blocked(const TimePoint now = Clock::now()) const
	{
		return m_proximity || (m_release_at.has_value() && now < *m_release_at);
	}

private:
	bool m_proximity = false;
	std::optional<TimePoint> m_release_at = std::nullopt;
};

} // namespace iptsd::apps::daemon

#endif // IPTSD_APPS_DAEMON_STYLUS_TOUCH_DELAY_HPP
