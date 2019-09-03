module eventcore.drivers.posix.signals;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.internal.utils : nogc_assert;

import std.algorithm.comparison : among;


final class SignalFDEventDriverSignals(Loop : PosixEventLoop) : EventDriverSignalsExt {
@safe: /*@nogc:*/ nothrow:
	import core.stdc.errno : errno, EAGAIN, EINPROGRESS;
	import core.sys.posix.signal;
	import core.sys.posix.unistd : close, read, write;
	import core.sys.linux.sys.signalfd;

	private Loop m_loop;

	this(Loop loop) @nogc { m_loop = loop; }

	override SignalListenID listen(int sig, SignalCallback on_signal)
	{
		return listenInternal([sig], SignalSlot(on_signal), false);
	}

	override SignalListenID listenMultiple(SignalInfoCallback on_signal, int[] sigs...)
	{
		return listenInternal(sigs, SignalSlot(null, on_signal), false);
	}

	package SignalListenID listenInternal(int[] sigs, SignalSlot slot, bool is_internal = true)
	{
		auto fd = () @trusted {
			sigset_t sset;
			sigemptyset(&sset);
			foreach (sig; sigs) {
				sigaddset(&sset, sig);
			}

			if (sigprocmask(SIG_BLOCK, &sset, null) != 0)
				return SignalListenID.invalid;

			return SignalListenID(signalfd(-1, &sset, SFD_NONBLOCK | SFD_CLOEXEC));
		} ();


		m_loop.initFD(cast(FD)fd, is_internal ? FDFlags.internal : FDFlags.none, slot);
		m_loop.registerFD(cast(FD)fd, EventMask.read);
		m_loop.setNotifyCallback!(EventType.read)(cast(FD)fd, &onSignal);

		onSignal(cast(FD)fd);

		return fd;
	}

	override void addRef(SignalListenID descriptor)
	{
		assert(m_loop.m_fds[descriptor].common.refCount > 0, "Adding reference to unreferenced event FD.");
		m_loop.m_fds[descriptor].common.refCount++;
	}

	override bool releaseRef(SignalListenID descriptor)
	{
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
		void callCb(SignalListenID lid, SignalStatus status, in ref signalfd_siginfo nfo) {
			auto siginfo_cb = m_loop.m_fds[fd].signal.siginfoCallback;
			if (siginfo_cb != null) {
				siginfo_t siginfo = {
					si_signo: nfo.ssi_signo,
					si_errno: nfo.ssi_errno,
					si_code: nfo.ssi_code,
				};
				if (siginfo.si_code == SI_QUEUE) {
					() @trusted {
						siginfo.si_pid = nfo.ssi_pid;
						siginfo.si_uid = nfo.ssi_uid;
						siginfo.si_value.sival_ptr = cast(void*) nfo.ssi_ptr;
						siginfo.si_value.sival_int = nfo.ssi_int;
					}();
				}
				siginfo_cb(lid, status, siginfo);
				return;
			}
			auto cb = m_loop.m_fds[fd].signal.callback;
			cb(lid, status, status == SignalStatus.error ? -1 : nfo.ssi_signo);
		}

		SignalListenID lid = cast(SignalListenID)fd;
		signalfd_siginfo nfo;
		do {
			auto ret = () @trusted { return read(cast(int)fd, &nfo, nfo.sizeof); } ();
			if (ret == -1 && errno.among!(EAGAIN, EINPROGRESS))
				break;
			if (ret != nfo.sizeof) {
				callCb(lid, SignalStatus.error, nfo);
				return;
			}
			addRef(lid);
			callCb(lid, SignalStatus.ok, nfo);
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
	SignalInfoCallback siginfoCallback;
}
