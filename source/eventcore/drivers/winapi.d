/**
	WinAPI based event driver implementation.

	This driver uses overlapped I/O to model asynchronous I/O operations
	efficiently. The driver's event loop processes UI messages, so that
	it integrates with GUI applications transparently.
*/
module eventcore.drivers.winapi;

version (Windows):

import eventcore.driver;
import std.socket : Address;
import core.time : Duration;


final class WinAPIEventDriver : EventDriver {
@safe: /*@nogc:*/ nothrow:

	private {
		WinAPIEventDriverCore m_core;
		WinAPIEventDriverFiles m_files;
		WinAPIEventDriverSockets m_sockets;
		WinAPIEventDriverDNS m_dns;
		WinAPIEventDriverTimers m_timers;
		WinAPIEventDriverEvents m_events;
		WinAPIEventDriverSignals m_signals;
		WinAPIEventDriverWatchers m_watchers;
	}

	this()
	{
		m_core = new WinAPIEventDriverCore();
		m_files = new WinAPIEventDriverFiles();
		m_sockets = new WinAPIEventDriverSockets();
		m_dns = new WinAPIEventDriverDNS();
		m_timers = new WinAPIEventDriverTimers();
		m_events = new WinAPIEventDriverEvents();
		m_signals = new WinAPIEventDriverSignals();
		m_watchers = new WinAPIEventDriverWatchers();
	}

	override @property WinAPIEventDriverCore core() { return m_core; }
	override @property WinAPIEventDriverFiles files() { return m_files; }
	override @property WinAPIEventDriverSockets sockets() { return m_sockets; }
	override @property WinAPIEventDriverDNS dns() { return m_dns; }
	override @property WinAPIEventDriverTimers timers() { return m_timers; }
	override @property WinAPIEventDriverEvents events() { return m_events; }
	override @property shared(WinAPIEventDriverEvents) events() shared { return m_events; }
	override @property WinAPIEventDriverSignals signals() { return m_signals; }
	override @property WinAPIEventDriverWatchers watchers() { return m_watchers; }

	override void dispose()
	{
		assert(false, "TODO!");
	}
}

final class WinAPIEventDriverCore : EventDriverCore {
@safe: /*@nogc:*/ nothrow:
	override size_t waiterCount()
	{
		assert(false, "TODO!");
	}

	override ExitReason processEvents(Duration timeout = Duration.max)
	{
		assert(false, "TODO!");
	}

	override void exit()
	{
		assert(false, "TODO!");
	}

	override void clearExitFlag()
	{
		assert(false, "TODO!");
	}

	protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system
	{
		assert(false, "TODO!");
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

	override void write(FileFD file, ulong offset, const(ubyte)[] buffer, FileIOCallback on_write_finish)
	{
		assert(false, "TODO!");
	}

	override void read(FileFD file, ulong offset, ubyte[] buffer, FileIOCallback on_read_finish)
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
