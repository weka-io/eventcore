/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import std.datetime : Clock, SysTime, UTC;
import std.stdio : writefln;
import core.time : Duration, msecs;

SysTime s_startTime;
int s_cnt = 0;
bool s_done;

void main()
{
	s_startTime = Clock.currTime(UTC());

	auto tm = eventDriver.timers.create();
	eventDriver.timers.wait(tm, (tm) nothrow @safe {
		scope (failure) assert(false);

		auto dur = Clock.currTime(UTC()) - s_startTime;
		assert(dur > 200.msecs);
		assert(dur < 220.msecs);	

		s_startTime = Clock.currTime(UTC());
		eventDriver.timers.set(tm, 100.msecs, 100.msecs);

		void secondTier(TimerID timer) nothrow @safe {
			scope (failure) assert(false);
			auto dur = Clock.currTime(UTC()) - s_startTime;
			s_cnt++;
			assert(dur > 100.msecs * s_cnt);
			assert(dur < 100.msecs * s_cnt + 20.msecs);

			if (s_cnt == 3) {
				s_done = true;
				eventDriver.core.exit();
			} else eventDriver.timers.wait(tm, &secondTier);
		}

		eventDriver.timers.wait(tm, &secondTier);
	});

	eventDriver.timers.set(tm, 200.msecs, 0.msecs);

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	//assert(er == ExitReason.outOfWaiters); // FIXME: see above
	assert(s_done);
	s_done = false;
}
