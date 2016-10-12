module eventcore.core;

public import eventcore.driver;

import eventcore.drivers.epoll;
import eventcore.drivers.libasync;
import eventcore.drivers.select;
import eventcore.drivers.posix;

version (Have_libasync) alias NativeEventDriver = LibasyncEventDriver;
else version (linux) alias NativeEventDriver = PosixEventDriver!EpollEventLoop;
else alias NativeEventDriver = PosixEventDriver!SelectEventLoop;

@property EventDriver eventDriver()
@safe @nogc nothrow {
	assert(s_driver !is null, "eventcore.core static constructor didn't run!?");
	return s_driver;
}

static this()
{
	if (!s_driver) s_driver = new NativeEventDriver;
}

shared static this()
{
	s_driver = new NativeEventDriver;
}

private NativeEventDriver s_driver;
