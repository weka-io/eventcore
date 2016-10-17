/**
	BSD kqueue based event driver implementation.

	Kqueue is an efficient API for asynchronous I/O on BSD flavors, including
	OS X/macOS, suitable for large numbers of concurrently open sockets.
*/
module eventcore.drivers.kqueue;
@safe: /*@nogc:*/ nothrow:

version (FreeBSD) enum have_kqueue = true;
else version (OSX) enum have_kqueue = true;
else enum have_kqueue = false;

static if (have_kqueue):

public import eventcore.drivers.posix;
import eventcore.internal.utils;

import core.time : Duration;
import core.sys.posix.sys.time : timespec;

version (OSX) import core.sys.darwin.sys.event;
else version (FreeBSD) import core.sys.freebsd.sys.event;
else static assert(false, "Kqueue not supported on this OS.");


import core.sys.linux.epoll;


final class KqueueEventLoop : PosixEventLoop {
	private {
		int m_queue;
		kevent[] m_fds;
		kevent[] m_events;
	}

	this()
	{
		m_queue = kqueue();
		enforce(m_queue >= 0, "Failed to create kqueue.");
	}

	override bool doProcessEvents(Duration timeout)
	@trusted {
		import std.algorithm : min;
		//assert(Fiber.getThis() is null, "processEvents may not be called from within a fiber!");

		//print("wait %s", m_events.length);
		timespec ts;
		long secs, hnsecs;
		dur.split!("seconds", "hnsecs")(secs, hnsecs);
		ts.tv_sec = cast(time_t)secs;
		ts.tv_nsec = hnsecs * 100;

		auto ret = kevent(m_queue, m_fds, m_fds.length, m_events, m_events.length, timeout == Duration.max ? null : &ts);

		if (ret > 0) {
			foreach (ref evt; m_events[0 .. ret]) {
				//print("event %s %s", evt.data.fd, evt.events);
				auto fd = cast(FD)evt.ident;
				if (evt.flags & EV_READ) notify!(EventType.read)(fd);
				if (evt.flags & EV_WRITE) notify!(EventType.write)(fd);
				if (evt.flags & EV_ERROR) notify!(EventType.status)(fd);
				else if (evt.flags & EV_EOF) notify!(EventType.status)(fd);
				// EV_SIGNAL, EV_TIMEOUT
			}
			return true;
		} else return false;
	}

	override void dispose()
	{

		import core.sys.posix.unistd : close;
		close(m_queue);
	}

	override void registerFD(FD fd, EventMask mask)
	{
		//print("register %s %s", fd, mask);
		auto idx = allocSlot(fd);
		kevent* ev = &m_events[idx];
		ev.ident = fd;
		ev.flags = EV_ADD|EV_ET|EV_ENABLE;
		if (mask & EventMask.read) ev.filter |= EVFILT_READ;
		if (mask & EventMask.write) ev.filter |= EVFILT_WRITE;
		if (mask & EventMask.status) ev.events |= EPOLLERR|EPOLLRDHUP;
	}

	override void unregisterFD(FD fd)
	{
		auto idx = m_eventMap[fd];
		m_events[idx].flags = EV_REMOVE;
	}

	override void updateFD(FD fd, EventMask mask)
	{
		//print("update %s %s", fd, mask);
		auto idx = m_eventMap[fd];
		epoll_event* ev = &m_events[idx];
		ev.filter = 0;
		ev.events |= EPOLLET;
		if (mask & EventMask.read) ev.filter |= EVFILT_READ;
		if (mask & EventMask.write) ev.filter |= EVFILT_WRITE;
		if (mask & EventMask.status) ev.events |= EPOLLERR|EPOLLRDHUP;
	}
}
