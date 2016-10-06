/**
	Linux epoll based event driver implementation.

	Epoll is an efficient API for asynchronous I/O on Linux, suitable for large
	numbers of concurrently open sockets.
*/
module eventcore.drivers.epoll;
@safe: /*@nogc:*/ nothrow:

version (linux):

public import eventcore.drivers.posix;
import eventcore.internal.utils;

import core.time : Duration;
import core.sys.posix.sys.time : timeval;
import core.sys.linux.epoll;


final class EpollEventDriver : PosixEventDriver {
	private {
		int m_epoll;
		epoll_event[] m_events;
	}

	this()
	{
		m_epoll = () @trusted { return epoll_create1(0); } ();
		m_events.length = 100;
	}

	nothrow @safe {
		override @property EpollEventDriver core() { return this; }
		override @property EpollEventDriver sockets() { return this; }
		override @property EpollEventDriver timers() { return this; }
		override @property EpollEventDriver events() { return this; }
		override @property EpollEventDriver signals() { return this; }
		override @property EpollEventDriver watchers() { return this; }
	}

	override bool doProcessEvents(Duration timeout)
	@trusted {
		import std.algorithm : min;
		//assert(Fiber.getThis() is null, "processEvents may not be called from within a fiber!");

		//print("wait %s", m_events.length);
		long tomsec;
		if (timeout == Duration.max) tomsec = long.max;
		else tomsec = (timeout.total!"hnsecs" + 9999) / 10_000;
		auto ret = epoll_wait(m_epoll, m_events.ptr, cast(int)m_events.length, tomsec > int.max ? -1 : cast(int)tomsec);
		//print("wait done %s", ret);

		if (ret > 0) {
			foreach (ref evt; m_events[0 .. ret]) {
				//print("event %s %s", evt.data.fd, evt.events);
				auto fd = cast(FD)evt.data.fd;
				if (evt.events & EPOLLIN) notify!(EventType.read)(fd);
				if (evt.events & EPOLLOUT) notify!(EventType.write)(fd);
				if (evt.events & EPOLLERR) notify!(EventType.status)(fd);
				else if (evt.events & EPOLLHUP) notify!(EventType.status)(fd);
			}
			return true;
		} else return false;
	}

	override void dispose()
	{
		import core.sys.posix.unistd : close;
		super.dispose();
		close(m_epoll);
	}

	override void registerFD(FD fd, EventMask mask)
	{
		//print("register %s %s", fd, mask);
		epoll_event ev;
		ev.events |= EPOLLET;
		if (mask & EventMask.read) ev.events |= EPOLLIN;
		if (mask & EventMask.write) ev.events |= EPOLLOUT;
		if (mask & EventMask.status) ev.events |= EPOLLERR|EPOLLRDHUP;
		ev.data.fd = fd;
		() @trusted { epoll_ctl(m_epoll, EPOLL_CTL_ADD, fd, &ev); } ();
	}

	override void unregisterFD(FD fd)
	{
		() @trusted { epoll_ctl(m_epoll, EPOLL_CTL_DEL, fd, null); } ();
	}

	override void updateFD(FD fd, EventMask mask)
	{
		//print("update %s %s", fd, mask);
		epoll_event ev;
		ev.events |= EPOLLET;
		//ev.events = EPOLLONESHOT;
		if (mask & EventMask.read) ev.events |= EPOLLIN;
		if (mask & EventMask.write) ev.events |= EPOLLOUT;
		if (mask & EventMask.status) ev.events |= EPOLLERR|EPOLLRDHUP;
		ev.data.fd = fd;
		() @trusted { epoll_ctl(m_epoll, EPOLL_CTL_MOD, fd, &ev); } ();
	}
}

private timeval toTimeVal(Duration dur)
{
	timeval tvdur;
	dur.split!("seconds", "usecs")(tvdur.tv_sec, tvdur.tv_usec);
	return tvdur;
}
