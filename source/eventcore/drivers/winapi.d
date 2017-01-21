/**
	WinAPI based event driver implementation.

	This driver uses overlapped I/O to model asynchronous I/O operations
	efficiently. The driver's event loop processes UI messages, so that
	it integrates with GUI applications transparently.
*/
module eventcore.drivers.winapi;

version (Windows):

import eventcore.driver;
import eventcore.drivers.timer;
import std.socket : Address;
import core.time : Duration;
import core.sys.windows.windows;
import core.sys.windows.winsock2;


final class WinAPIEventDriver : EventDriver {
	private {
		WinAPIEventDriverCore m_core;
		WinAPIEventDriverFiles m_files;
		WinAPIEventDriverSockets m_sockets;
		WinAPIEventDriverDNS m_dns;
		LoopTimeoutTimerDriver m_timers;
		WinAPIEventDriverEvents m_events;
		WinAPIEventDriverSignals m_signals;
		WinAPIEventDriverWatchers m_watchers;
	}

	this()
	@safe {
		import std.exception : enforce;

		WSADATA wd;
		enforce(() @trusted { return WSAStartup(0x0202, &wd); } () == 0, "Failed to initialize WinSock");

		m_events = new WinAPIEventDriverEvents();
		m_signals = new WinAPIEventDriverSignals();
		m_timers = new LoopTimeoutTimerDriver();
		m_core = new WinAPIEventDriverCore(m_timers);
		m_files = new WinAPIEventDriverFiles();
		m_sockets = new WinAPIEventDriverSockets();
		m_dns = new WinAPIEventDriverDNS();
		m_watchers = new WinAPIEventDriverWatchers();
	}

@safe: /*@nogc:*/ nothrow:

	override @property WinAPIEventDriverCore core() { return m_core; }
	override @property WinAPIEventDriverFiles files() { return m_files; }
	override @property WinAPIEventDriverSockets sockets() { return m_sockets; }
	override @property WinAPIEventDriverDNS dns() { return m_dns; }
	override @property LoopTimeoutTimerDriver timers() { return m_timers; }
	override @property WinAPIEventDriverEvents events() { return m_events; }
	override @property shared(WinAPIEventDriverEvents) events() shared { return m_events; }
	override @property WinAPIEventDriverSignals signals() { return m_signals; }
	override @property WinAPIEventDriverWatchers watchers() { return m_watchers; }

	override void dispose()
	{
	}
}

final class WinAPIEventDriverCore : EventDriverCore {
@safe: /*@nogc:*/ nothrow:
	private {
		bool m_exit;
		size_t m_waiterCount;
		DWORD m_tid;
		LoopTimeoutTimerDriver m_timers;
		HANDLE[] m_registeredEvents;
		HANDLE m_fileCompletionEvent;
	}

	this(LoopTimeoutTimerDriver timers)
	{
		m_timers = timers;
		m_tid = () @trusted { return GetCurrentThreadId(); } ();
		m_fileCompletionEvent = () @trusted { return CreateEventW(null, false, false, null); } ();
		m_registeredEvents ~= m_fileCompletionEvent;
	}

	override size_t waiterCount() { return m_waiterCount; }

	override ExitReason processEvents(Duration timeout = Duration.max)
	{
		import std.algorithm : min;
		import core.time : hnsecs, seconds;

		if (m_exit) {
			m_exit = false;
			return ExitReason.exited;
		}

		bool got_event;

		if (timeout <= 0.seconds) {
			got_event = doProcessEvents(0.seconds);
			got_event |= m_timers.process(currStdTime);
			return got_event ? ExitReason.idle : ExitReason.timeout;
		} else {
			long now = currStdTime;
			do {
				auto nextto = min(m_timers.getNextTimeout(now), timeout);
				got_event |= doProcessEvents(nextto);
				long prev_step = now;
				now = currStdTime;
				got_event |= m_timers.process(now);

				if (m_exit) {
					m_exit = false;
					return ExitReason.exited;
				}
				if (timeout != Duration.max)
					timeout -= (now - prev_step).hnsecs;
			} while (timeout > 0.seconds);
		}

		if (!waiterCount) return ExitReason.outOfWaiters;
		if (got_event) return ExitReason.idle;
		return ExitReason.timeout;
	}

	override void exit()
	@trusted {
		m_exit = true;
		PostThreadMessageW(m_tid, WM_QUIT, 0, 0);
	}

	override void clearExitFlag()
	{
		m_exit = false;
	}

	protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system
	{
		assert(false, "TODO!");
	}

	protected override void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system
	{
		assert(false, "TODO!");
	}

	private bool doProcessEvents(Duration max_wait)
	{
		import core.time : seconds;
		import std.algorithm.comparison : min;

		bool got_event;

		if (max_wait > 0.seconds) {
			DWORD timeout_msecs = max_wait == Duration.max ? INFINITE : cast(DWORD)min(max_wait.total!"msecs", DWORD.max);
			auto ret = () @trusted { return MsgWaitForMultipleObjectsEx(cast(DWORD)m_registeredEvents.length, m_registeredEvents.ptr,
				timeout_msecs, QS_ALLEVENTS, MWMO_ALERTABLE|MWMO_INPUTAVAILABLE); } ();
			
			/*if (ret == WAIT_OBJECT_0) {
				got_event = true;
				Win32TCPConnection[] to_remove;
				foreach( fw; m_fileWriters.byKey )
					if( fw.testFileWritten() )
						to_remove ~= fw;
				foreach( fw; to_remove )
				m_fileWriters.remove(fw);
			}*/
		}

		MSG msg;
		//uint cnt = 0;
		while (() @trusted { return PeekMessageW(&msg, null, 0, 0, PM_REMOVE); } ()) {
			if( msg.message == WM_QUIT ) {
				m_exit = true;
				return false;
			}
			() @trusted {
				TranslateMessage(&msg);
				DispatchMessageW(&msg);
			} ();

			got_event = true;

			// process timers every now and then so that they don't get stuck
			//if (++cnt % 10 == 0) processTimers();
		}

		return got_event;
	}
}

final class WinAPIEventDriverSockets : EventDriverSockets {
@safe: /*@nogc:*/ nothrow:
	override StreamSocketFD connectStream(scope Address peer_address, scope Address bind_address, ConnectCallback on_connect)
	{
		assert(false, "TODO!");
	}

	override StreamListenSocketFD listenStream(scope Address bind_address, AcceptCallback on_accept)
	{
		assert(false, "TODO!");
	}

	override void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept)
	{
		assert(false, "TODO!");
	}

	override ConnectionState getConnectionState(StreamSocketFD sock)
	{
		assert(false, "TODO!");
	}

	override bool getLocalAddress(StreamSocketFD sock, scope RefAddress dst)
	{
		assert(false, "TODO!");
	}

	override void setTCPNoDelay(StreamSocketFD socket, bool enable)
	{
		assert(false, "TODO!");
	}

	override void setKeepAlive(StreamSocketFD socket, bool enable)
	{
		assert(false, "TODO!");
	}

	override void read(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish)
	{
		assert(false, "TODO!");
	}

	override void write(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish)
	{
		assert(false, "TODO!");
	}

	override void waitForData(StreamSocketFD socket, IOCallback on_data_available)
	{
		assert(false, "TODO!");
	}

	override void shutdown(StreamSocketFD socket, bool shut_read = true, bool shut_write = true)
	{
		assert(false, "TODO!");
	}

	override void cancelRead(StreamSocketFD socket)
	{
		assert(false, "TODO!");
	}

	override void cancelWrite(StreamSocketFD socket)
	{
		assert(false, "TODO!");
	}

	override DatagramSocketFD createDatagramSocket(scope Address bind_address, scope Address target_address)
	{
		assert(false, "TODO!");
	}

	override bool setBroadcast(DatagramSocketFD socket, bool enable)
	{
		assert(false, "TODO!");
	}

	override void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_receive_finish)
	{
		assert(false, "TODO!");
	}

	override void cancelReceive(DatagramSocketFD socket)
	{
		assert(false, "TODO!");
	}

	override void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, Address target_address, DatagramIOCallback on_send_finish)
	{
		assert(false, "TODO!");
	}

	override void cancelSend(DatagramSocketFD socket)
	{
		assert(false, "TODO!");
	}

	override void addRef(SocketFD descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(SocketFD descriptor)
	{
		assert(false, "TODO!");
	}
}

final class WinAPIEventDriverDNS : EventDriverDNS {
@safe: /*@nogc:*/ nothrow:

	DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished)
	{
		assert(false, "TODO!");
	}

	void cancelLookup(DNSLookupID handle)
	{
		assert(false, "TODO!");
	}
}


final class WinAPIEventDriverFiles : EventDriverFiles {
@safe: /*@nogc:*/ nothrow:
	override FileFD open(string path, FileOpenMode mode)
	{
		assert(false, "TODO!");
	}

	override FileFD adopt(int system_handle)
	{
		assert(false, "TODO!");
	}

	override void close(FileFD file)
	{
		assert(false, "TODO!");
	}

	override ulong getSize(FileFD file)
	{
		assert(false, "TODO!");
	}

	override void write(FileFD file, ulong offset, const(ubyte)[] buffer, IOMode mode, FileIOCallback on_write_finish)
	{
		assert(false, "TODO!");
	}

	override void read(FileFD file, ulong offset, ubyte[] buffer, IOMode mode, FileIOCallback on_read_finish)
	{
		assert(false, "TODO!");
	}

	override void cancelWrite(FileFD file)
	{
		assert(false, "TODO!");
	}

	override void cancelRead(FileFD file)
	{
		assert(false, "TODO!");
	}

	override void addRef(FileFD descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(FileFD descriptor)
	{
		assert(false, "TODO!");
	}
}

final class WinAPIEventDriverEvents : EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
	override EventID create()
	{
		assert(false, "TODO!");
	}

	override void trigger(EventID event, bool notify_all = true)
	{
		assert(false, "TODO!");
	}

	override void trigger(EventID event, bool notify_all = true) shared
	{
		assert(false, "TODO!");
	}

	override void wait(EventID event, EventCallback on_event)
	{
		assert(false, "TODO!");
	}

	override void cancelWait(EventID event, EventCallback on_event)
	{
		assert(false, "TODO!");
	}

	override void addRef(EventID descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(EventID descriptor)
	{
		assert(false, "TODO!");
	}
}

final class WinAPIEventDriverSignals : EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	override SignalListenID listen(int sig, SignalCallback on_signal)
	{
		assert(false, "TODO!");
	}

	override void addRef(SignalListenID descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(SignalListenID descriptor)
	{
		assert(false, "TODO!");
	}
}

final class WinAPIEventDriverTimers : EventDriverTimers {
@safe: /*@nogc:*/ nothrow:
	override TimerID create()
	{
		assert(false, "TODO!");
	}

	override void set(TimerID timer, Duration timeout, Duration repeat = Duration.zero)
	{
		assert(false, "TODO!");
	}

	override void stop(TimerID timer)
	{
		assert(false, "TODO!");
	}

	override bool isPending(TimerID timer)
	{
		assert(false, "TODO!");
	}

	override bool isPeriodic(TimerID timer)
	{
		assert(false, "TODO!");
	}

	override void wait(TimerID timer, TimerCallback callback)
	{
		assert(false, "TODO!");
	}

	override void cancelWait(TimerID timer)
	{
		assert(false, "TODO!");
	}

	override void addRef(TimerID descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(TimerID descriptor)
	{
		assert(false, "TODO!");
	}
}

final class WinAPIEventDriverWatchers : EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback)
	{
		assert(false, "TODO!");
	}

	override void addRef(WatcherID descriptor)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(WatcherID descriptor)
	{
		assert(false, "TODO!");
	}
}

private long currStdTime()
@safe nothrow {
	import std.datetime : Clock;
	scope (failure) assert(false);
	return Clock.currStdTime;
}
