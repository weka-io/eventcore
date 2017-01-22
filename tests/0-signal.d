/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import std.stdio : writefln;
import core.stdc.signal;
import core.sys.posix.signal : SIGRTMIN;
import core.time : Duration, msecs;

bool s_done;

void main()
{
	version (OSX) writefln("Signals are not yet supported on macOS. Skipping test.");
	else {

	auto id = eventDriver.signals.listen(SIGRTMIN+1, (id, status, sig) {
		assert(!s_done);
		assert(status == SignalStatus.ok);
		assert(sig == () @trusted { return SIGRTMIN+1; } ());
		s_done = true;
		eventDriver.core.exit();
	});

	auto tm = eventDriver.timers.create();
	eventDriver.timers.set(tm, 500.msecs, 0.msecs);
	eventDriver.timers.wait(tm, (tm) {
		() @trusted { raise(SIGRTMIN+1); } ();
	});

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	//assert(er == ExitReason.outOfWaiters); // FIXME: see above
	assert(s_done);
	s_done = false;

	}
}
