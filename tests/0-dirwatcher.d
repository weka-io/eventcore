/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import std.stdio : File, writefln;
import std.file : exists, remove;
import core.time : Duration, msecs;

bool s_done;
int s_cnt = 0;

enum testFilename = "test.dat";

void main()
{
	version (OSX) writefln("Directory watchers are not yet supported on macOS. Skipping test.");
	else {

	if (exists(testFilename))
		remove(testFilename);

	auto id = eventDriver.watchers.watchDirectory(".", false, (id, ref change) {
		switch (s_cnt++) {
			default: assert(false);
			case 0:
				assert(change.kind == FileChangeKind.added);
				assert(change.directory == ".");
				assert(change.name == testFilename);
				break;
			case 1:
				assert(change.kind == FileChangeKind.modified);
				assert(change.directory == ".");
				assert(change.name == testFilename);
				break;
			case 2:
				assert(change.kind == FileChangeKind.removed);
				assert(change.directory == ".");
				assert(change.name == testFilename);
				s_done = true;
				eventDriver.core.exit();
				break;
		}
	});

	auto fil = File(testFilename, "wt");

	auto tm = eventDriver.timers.create();
	eventDriver.timers.set(tm, 100.msecs, 0.msecs);
	eventDriver.timers.wait(tm, (tm) {
		scope (failure) assert(false);
		fil.write("test");
		fil.close();
		eventDriver.timers.set(tm, 100.msecs, 0.msecs);
		eventDriver.timers.wait(tm, (tm) {
			scope (failure) assert(false);
			remove(testFilename);
		});
	});

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	//assert(er == ExitReason.outOfWaiters); // FIXME: see above
	assert(s_done);
	s_done = false;

	}
}
