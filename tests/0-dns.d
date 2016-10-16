/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import std.stdio : writefln;

bool s_done;

void main()
{
	eventDriver.dns.lookupHost("example.org", (id, status, scope addrs) {
		assert(status == DNSStatus.ok);
		assert(addrs.length >= 1);
		foreach (a; addrs) {
			scope (failure) assert(false);
			writefln("%s (%s)", a.toAddrString(), a.toServiceNameString());
		}
		s_done = true;
		eventDriver.core.exit();
	});

	ExitReason er;
	do er = eventDriver.core.processEvents();
	while (er == ExitReason.idle);
	//assert(er == ExitReason.outOfWaiters); // FIXME: see above
	assert(s_done);
	s_done = false;
}
