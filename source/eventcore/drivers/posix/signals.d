module eventcore.drivers.posix.signals;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.internal.utils : nogc_assert;

import std.algorithm.comparison : among;


final class SignalFDEventDriverSignals(Loop : PosixEventLoop) : EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	import core.stdc.errno : errno, EAGAIN, EINPROGRESS;
	import core.sys.posix.signal;
	import core.sys.posix.unistd : close, read, write;
	import core.sys.linux.sys.signalfd;

	private Loop m_loop;

	this(Loop loop) @nogc { m_loop = loop; }

	override SignalListenID listen(int sig, SignalCallback on_signal)
	{
		return listenInternal(sig, on_signal, false);
	}

	package SignalListenID listenInternal(int sig, SignalCallback on_signal, bool is_internal = true)
	{
		auto sigfd = () @trusted {
			sigset_t sset;
			sigemptyset(&sset);
			sigaddset(&sset, sig);

			if (sigprocmask(SIG_BLOCK, &sset, null) != 0)
				return -1;

			return signalfd(-1, &sset, SFD_NONBLOCK | SFD_CLOEXEC);
		} ();


		auto fd = m_loop.initFD!SignalListenID(sigfd, is_internal ? FDFlags.internal : FDFlags.none, SignalSlot(on_signal));
		m_loop.registerFD(cast(FD)fd, EventMask.read);
		m_loop.setNotifyCallback!(EventType.read)(cast(FD)fd, &onSignal);

		onSignal(cast(FD)fd);

		return fd;
	}

	override bool isValid(SignalListenID handle)
	const {
		if (handle.value >= m_loop.m_fds.length) return false;
		return m_loop.m_fds[handle.value].common.validationCounter == handle.validationCounter;
	}

	override void addRef(SignalListenID descriptor)
	{
		if (!isValid(descriptor)) return;

		assert(m_loop.m_fds[descriptor].common.refCount > 0, "Adding reference to unreferenced event FD.");
		m_loop.m_fds[descriptor].common.refCount++;
	}

	override bool releaseRef(SignalListenID descriptor)
	{
		if (!isValid(descriptor)) return true;

		FD fd = cast(FD)descriptor;
		nogc_assert(m_loop.m_fds[fd].common.refCount > 0, "Releasing reference to unreferenced event FD.");
		if (--m_loop.m_fds[fd].common.refCount == 1) { // NOTE: 1 because setNotifyCallback adds a second reference
			m_loop.setNotifyCallback!(EventType.read)(fd, null);
			m_loop.unregisterFD(fd, EventMask.read);
			m_loop.clearFD!SignalSlot(fd);
			close(cast(int)fd);
			return false;
		}
		return true;
	}

	private void onSignal(FD fd)
	{
		SignalListenID lid = cast(SignalListenID)fd;
		signalfd_siginfo nfo;
		do {
			auto ret = () @trusted { return read(cast(int)fd, &nfo, nfo.sizeof); } ();
			if (ret == -1 && errno.among!(EAGAIN, EINPROGRESS))
				break;
			auto cb = m_loop.m_fds[fd].signal.callback;
			if (ret != nfo.sizeof) {
				cb(lid, SignalStatus.error, -1);
				return;
			}
			addRef(lid);
			cb(lid, SignalStatus.ok, nfo.ssi_signo);
			releaseRef(lid);
		} while (m_loop.m_fds[fd].common.refCount > 0);
	}
}

final class DummyEventDriverSignals(Loop : PosixEventLoop) : EventDriverSignals {
@safe: /*@nogc:*/ nothrow:

	private Loop m_loop;

	this(Loop loop) { m_loop = loop; }

	override SignalListenID listen(int sig, SignalCallback on_signal)
	{
		return listenInternal(sig, on_signal, false);
	}

	package SignalListenID listenInternal(int sig, SignalCallback on_signal, bool is_internal = true)
	{
		assert(false);
	}

	override bool isValid(SignalListenID handle)
	const {
		return false;
	}

	override void addRef(SignalListenID descriptor)
	{
		assert(false);
	}

	override bool releaseRef(SignalListenID descriptor)
	{
		assert(false);
	}
}

package struct SignalSlot {
	alias Handle = SignalListenID;
	SignalCallback callback;
}
