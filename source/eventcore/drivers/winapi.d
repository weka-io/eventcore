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
import eventcore.internal.consumablequeue : ConsumableQueue;
import eventcore.internal.utils;
import eventcore.internal.win32;
import taggedalgebraic;
import core.sys.windows.windows;
import core.sys.windows.winsock2;
import core.time : Duration;
import std.experimental.allocator;
import std.socket : Address;

static assert(HANDLE.sizeof <= FD.BaseType.sizeof);
static assert(FD(cast(int)INVALID_HANDLE_VALUE) == FD.init);


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

	static WinAPIEventDriver threadInstance;

	this()
	@safe {
		assert(threadInstance is null);
		threadInstance = this;

		import std.exception : enforce;

		WSADATA wd;
		enforce(() @trusted { return WSAStartup(0x0202, &wd); } () == 0, "Failed to initialize WinSock");

		m_signals = new WinAPIEventDriverSignals();
		m_timers = new LoopTimeoutTimerDriver();
		m_core = new WinAPIEventDriverCore(m_timers);
		m_events = new WinAPIEventDriverEvents(m_core);
		m_files = new WinAPIEventDriverFiles(m_core);
		m_sockets = new WinAPIEventDriverSockets();
		m_dns = new WinAPIEventDriverDNS();
		m_watchers = new WinAPIEventDriverWatchers(m_core);
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
		m_events.dispose();
		assert(threadInstance !is null);
		threadInstance = null;
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
		void delegate() @safe nothrow[HANDLE] m_eventCallbacks;
		HANDLE m_fileCompletionEvent;

		HandleSlot[HANDLE] m_handles; // FIXME: use allocator based hash map
	}

	this(LoopTimeoutTimerDriver timers)
	{
		m_timers = timers;
		m_tid = () @trusted { return GetCurrentThreadId(); } ();
		m_fileCompletionEvent = () @trusted { return CreateEventW(null, false, false, null); } ();
		registerEvent(m_fileCompletionEvent);
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
			
			if (ret >= WAIT_OBJECT_0 && ret < WAIT_OBJECT_0 + m_registeredEvents.length) {
				if (auto pc = m_registeredEvents[ret - WAIT_OBJECT_0] in m_eventCallbacks)
					(*pc)();
			}
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


	private void registerEvent(HANDLE event, void delegate() @safe nothrow callback = null)
	{
		m_registeredEvents ~= event;
		if (callback) m_eventCallbacks[event] = callback;
	}

	private SlotType* setupSlot(SlotType)(HANDLE h)
	{
		assert(h !in m_handles, "Handle already in use.");
		HandleSlot s;
		s.refCount = 1;
		s.specific = SlotType.init;
		m_handles[h] = s;
		return () @trusted { return &m_handles[h].specific.get!SlotType(); } ();
	}

	private void freeSlot(HANDLE h)
	{
		assert(h in m_handles, "Handle not in use - cannot free.");
		m_handles.remove(h);
	}
}

final class WinAPIEventDriverSockets : EventDriverSockets {
@safe: /*@nogc:*/ nothrow:
	override StreamSocketFD connectStream(scope Address peer_address, scope Address bind_address, ConnectCallback on_connect)
	{
		assert(false, "TODO!");
	}

	override StreamSocketFD adoptStream(int socket)
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

	override DatagramSocketFD adoptDatagramSocket(int socket)
	{
		assert(false);
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
		import std.typecons : scoped;
		import std.utf : toUTF16z;

		auto id = DNSLookupID(0);

		static immutable ushort[] addrfamilies = [AF_INET, AF_INET6];

		const(WCHAR)* namew;
		try namew = name.toUTF16z;
		catch (Exception e) return DNSLookupID.invalid;

		foreach (af; addrfamilies) {
			//if (family != af && family != AF_UNSPEC) continue;

			SOCKADDR_STORAGE sa;
			INT addrlen = sa.sizeof;
			auto ret = () @trusted { return WSAStringToAddressW(namew, af, null, cast(sockaddr*)&sa, &addrlen); } ();
			if (ret != 0) continue;

			scope addr = new RefAddress(() @trusted { return cast(sockaddr*)&sa; } (), addrlen);
			RefAddress[1] addrs;
			addrs[0] = addr;
			on_lookup_finished(id, DNSStatus.ok, addrs);
			return id;
		}

		version(none){ // Windows 8+
			LookupStatus status;
			status.task = Task.getThis();
			status.driver = this;
			status.finished = false;

			WSAOVERLAPPEDX overlapped;
			overlapped.Internal = 0;
			overlapped.InternalHigh = 0;
			overlapped.hEvent = cast(HANDLE)cast(void*)&status;

			void* aif;
			ADDRINFOEXW addr_hint;
			ADDRINFOEXW* addr_ret;
			addr_hint.ai_family = family;
			addr_hint.ai_socktype = SOCK_STREAM;
			addr_hint.ai_protocol = IPPROTO_TCP;

			enforce(GetAddrInfoExW(namew, null, NS_DNS, null, &addr_hint, &addr_ret, null, &overlapped, &onDnsResult, null) == 0, "Failed to lookup host");
			while( !status.finished ) m_core.yieldForEvent();
			enforce(!status.error, "Failed to lookup host: "~to!string(status.error));

			aif = addr_ret;
			addr.family = cast(ubyte)addr_ret.ai_family;
			switch(addr.family){
				default: assert(false, "Invalid address family returned from host lookup.");
				case AF_INET: addr.sockAddrInet4 = *cast(sockaddr_in*)addr_ret.ai_addr; break;
				case AF_INET6: addr.sockAddrInet6 = *cast(sockaddr_in6*)addr_ret.ai_addr; break;
			}
			FreeAddrInfoExW(addr_ret);
		} else {
			ADDRINFOW* results;
			if (auto ret = () @trusted { return GetAddrInfoW(namew, null, null, &results); } ()) {
				on_lookup_finished(id, DNSStatus.error, null);
				return id;
			}

			scope(failure) assert(false);
			() @trusted {
				typeof(scoped!RefAddress())[16] addr_storage = [
					scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(),
					scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(),
					scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(),
					scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress(), scoped!RefAddress()
				];
				RefAddress[16] buf;
				size_t naddr = 0;
				while (results) {
					RefAddress addr = addr_storage[naddr];
					addr.set(results.ai_addr, results.ai_addrlen);
					buf[naddr++] = addr;
					results = results.ai_next;
				}

				on_lookup_finished(id, DNSStatus.ok, buf[0 .. naddr]);
			} ();
		}

		return id;
	}

	void cancelLookup(DNSLookupID handle)
	{
		assert(false, "TODO!");
	}
}


final class WinAPIEventDriverFiles : EventDriverFiles {
@safe /*@nogc*/ nothrow:
	private {
		WinAPIEventDriverCore m_core;
	}

	this(WinAPIEventDriverCore core)
	{
		m_core = core;
	}

	override FileFD open(string path, FileOpenMode mode)
	{
		import std.utf : toUTF16z;

		auto access = mode == FileOpenMode.readWrite || mode == FileOpenMode.createTrunc ? (GENERIC_WRITE | GENERIC_READ) :
						mode == FileOpenMode.append ? GENERIC_WRITE : GENERIC_READ;
		auto shareMode = mode == FileOpenMode.read ? FILE_SHARE_READ : 0;
		auto creation = mode == FileOpenMode.createTrunc ? CREATE_ALWAYS : mode == FileOpenMode.append? OPEN_ALWAYS : OPEN_EXISTING;

		auto handle = () @trusted {
			scope (failure) assert(false);
			return CreateFileW(path.toUTF16z, access, shareMode, null, creation,
				FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null);
		} ();
		auto errorcode = GetLastError();
		if (handle == INVALID_HANDLE_VALUE)
			return FileFD.invalid;

		if (mode == FileOpenMode.createTrunc && errorcode == ERROR_ALREADY_EXISTS) {
			BOOL ret = SetEndOfFile(handle);
			if (!ret) {
				CloseHandle(handle);
				return FileFD.init;
			}
		}

		return adopt(cast(int)handle);
	}

	override FileFD adopt(int system_handle)
	{
		auto handle = () @trusted { return cast(HANDLE)system_handle; } ();
		DWORD f;
		if (!() @trusted { return GetHandleInformation(handle, &f); } ())
			return FileFD.init;

		auto s = m_core.setupSlot!FileSlot(handle);
		s.read.handle = s.write.handle = handle;

		return FileFD(system_handle);
	}

	override void close(FileFD file)
	{
		auto h = idToHandle(file);
		auto slot = () @trusted { return &m_core.m_handles[h].file(); } ();
		if (slot.read.handle != INVALID_HANDLE_VALUE) {
			CloseHandle(h);
			slot.read.handle = slot.write.handle = INVALID_HANDLE_VALUE;
		}
	}

	override ulong getSize(FileFD file)
	{
		LARGE_INTEGER size;
		auto succeeded = () @trusted { return GetFileSizeEx(idToHandle(file), &size); } ();
		if (!succeeded || size.QuadPart < 0)
			return ulong.max;
		return size.QuadPart;
	}

	override void write(FileFD file, ulong offset, const(ubyte)[] buffer, IOMode mode, FileIOCallback on_write_finish)
	{
		if (!buffer.length) {
			on_write_finish(file, IOStatus.ok, 0);
			return;
		}

		auto h = idToHandle(file);
		auto slot = &m_core.m_handles[h].file.write;
		slot.bytesTransferred = 0;
		slot.offset = offset;
		slot.buffer = buffer;
		slot.mode = mode;
		slot.callback = on_write_finish;
		startIO!(WriteFileEx, true)(h, slot);
	}

	override void read(FileFD file, ulong offset, ubyte[] buffer, IOMode mode, FileIOCallback on_read_finish)
	{
		if (!buffer.length) {
			on_read_finish(file, IOStatus.ok, 0);
			return;
		}

		auto h = idToHandle(file);
		auto slot = &m_core.m_handles[h].file.read;
		slot.bytesTransferred = 0;
		slot.offset = offset;
		slot.buffer = buffer;
		slot.mode = mode;
		slot.callback = on_read_finish;
		startIO!(ReadFileEx, false)(h, slot);
	}

	override void cancelWrite(FileFD file)
	{
		auto h = idToHandle(file);
		cancelIO!true(h, m_core.m_handles[h].file.write);
	}

	override void cancelRead(FileFD file)
	{
		auto h = idToHandle(file);
		cancelIO!false(h, m_core.m_handles[h].file.read);
	}

	override void addRef(FileFD descriptor)
	{
		m_core.m_handles[idToHandle(descriptor)].addRef();
	}

	override bool releaseRef(FileFD descriptor)
	{
		auto h = idToHandle(descriptor);
		return m_core.m_handles[h].releaseRef({
			close(descriptor);
			m_core.freeSlot(h);
		});
	}

	private static void startIO(alias fun, bool RO)(HANDLE h, FileSlot.Direction!RO* slot)
	{
		import std.algorithm.comparison : min;

		with (slot.overlapped) {
			Internal = 0;
			InternalHigh = 0;
			Offset = cast(uint)(slot.offset & 0xFFFFFFFF);
			OffsetHigh = cast(uint)(slot.offset >> 32);
			hEvent = () @trusted { return cast(HANDLE)slot; } ();
		}

		auto nbytes = min(slot.buffer.length, DWORD.max);
		if (!() @trusted { return fun(h, &slot.buffer[0], nbytes, &slot.overlapped, &onIOFinished!(fun, RO)); } ()) {
			slot.invokeCallback(IOStatus.error, slot.bytesTransferred);
		}
	}

	private static void cancelIO(bool RO)(HANDLE h, ref FileSlot.Direction!RO slot)
	{
		if (slot.callback) {
			//CancelIoEx(h, &slot.overlapped); // FIXME: currently causes linker errors for DMD due to outdated kernel32.lib files
			slot.callback = null;
			slot.buffer = null;
		}
	}

	private static extern(Windows)
	void onIOFinished(alias fun, bool RO)(DWORD error, DWORD bytes_transferred, OVERLAPPED* overlapped)
	{

		auto slot = () @trusted { return cast(FileSlot.Direction!RO*)overlapped.hEvent; } ();
		assert(slot !is null);
		HANDLE h = slot.handle;
		auto id = FileFD(cast(int)h);

		if (!slot.callback) {
			// request was already cancelled
			return;
		}

		if (error != 0) {
			slot.invokeCallback(IOStatus.error, slot.bytesTransferred + bytes_transferred);
			return;
		}

		slot.bytesTransferred += bytes_transferred;
		slot.offset += bytes_transferred;

		if (slot.bytesTransferred >= slot.buffer.length || slot.mode != IOMode.all) {
			slot.invokeCallback(IOStatus.ok, slot.bytesTransferred);
		} else {
			startIO!(fun, RO)(h, slot);
		}
	}

	private static HANDLE idToHandle(FileFD id)
	@trusted {
		return cast(HANDLE)cast(int)id;
	}
}


final class WinAPIEventDriverEvents : EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
	private {
		static struct Trigger {
			EventID id;
			bool notifyAll;
		}

		static struct EventSlot {
			uint refCount;
			ConsumableQueue!EventCallback waiters;
		}

		WinAPIEventDriverCore m_core;
		HANDLE m_event;
		EventSlot[EventID] m_events;
		CRITICAL_SECTION m_mutex;
		ConsumableQueue!Trigger m_pending;
		uint m_idCounter;
	}

	this(WinAPIEventDriverCore core)
	{
		m_core = core;
		m_event = () @trusted { return CreateEvent(null, false, false, null); } ();
		m_pending = new ConsumableQueue!Trigger; // FIXME: avoid GC allocation
		InitializeCriticalSection(&m_mutex);
		m_core.registerEvent(m_event, &triggerPending);
	}

	void dispose()
	@trusted {
		scope (failure) assert(false);
		destroy(m_pending);
	}

	override EventID create()
	{
		auto id = EventID(m_idCounter++);
		if (id == EventID.invalid) id = EventID(m_idCounter++);
		m_events[id] = EventSlot(1, new ConsumableQueue!EventCallback); // FIXME: avoid GC allocation
		return id;
	}

	override void trigger(EventID event, bool notify_all = true)
	{
		auto pe = event in m_events;
		assert(pe !is null, "Invalid event ID passed to triggerEvent.");
		if (notify_all) {
			foreach (w; pe.waiters.consume)
				w(event);
		} else {
			if (!pe.waiters.empty)
				pe.waiters.consumeOne()(event);
		}
	}

	override void trigger(EventID event, bool notify_all = true) shared
	{
		import core.atomic : atomicStore;
		auto pe = event in m_events;
		assert(pe !is null, "Invalid event ID passed to shared triggerEvent.");

		() @trusted {
			auto thisus = cast(WinAPIEventDriverEvents)this;
			EnterCriticalSection(&thisus.m_mutex);
			thisus.m_pending.put(Trigger(event, notify_all));
			LeaveCriticalSection(&thisus.m_mutex);
			SetEvent(thisus.m_event);
		} ();
	}

	override void wait(EventID event, EventCallback on_event)
	{
		return m_events[event].waiters.put(on_event);
	}

	override void cancelWait(EventID event, EventCallback on_event)
	{
		import std.algorithm.searching : countUntil;
		import std.algorithm.mutation : remove;

		m_events[event].waiters.removePending(on_event);
	}

	override void addRef(EventID descriptor)
	{
		assert(m_events[descriptor].refCount > 0);
		m_events[descriptor].refCount++;
	}

	override bool releaseRef(EventID descriptor)
	{
		auto pe = descriptor in m_events;
		assert(pe.refCount > 0);
		if (--pe.refCount == 0) {
			() @trusted nothrow {
				scope (failure) assert(false);
				destroy(pe.waiters);
				CloseHandle(idToHandle(descriptor));
			} ();
			m_events.remove(descriptor);
			return false;
		}
		return true;
	}

	private void triggerPending()
	{
		while (true) {
			Trigger t;
			{
				() @trusted { EnterCriticalSection(&m_mutex); } ();
				scope (exit) () @trusted { LeaveCriticalSection(&m_mutex); } ();
				if (m_pending.empty) break;
				t = m_pending.consumeOne;
			}

			trigger(t.id, t.notifyAll);
		}
	}

	private static HANDLE idToHandle(EventID event)
	@trusted {
		return cast(HANDLE)cast(int)event;
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
	private {
		WinAPIEventDriverCore m_core;
	}

	this(WinAPIEventDriverCore core)
	{
		m_core = core;
	}

	override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback)
	{
		import std.utf : toUTF16z;
		auto handle = () @trusted {
			scope (failure) assert(false);
			return CreateFileW(path.toUTF16z, FILE_LIST_DIRECTORY,
				FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
				null, OPEN_EXISTING,
				FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
				null);
			} ();
		
		if (handle == INVALID_HANDLE_VALUE)
			return WatcherID.invalid;

		auto id = WatcherID(cast(int)handle);

		auto slot = m_core.setupSlot!WatcherSlot(handle);
		slot.directory = path;
		slot.recursive = recursive;
		slot.callback = callback;
		slot.buffer = () @trusted {
			try return theAllocator.makeArray!ubyte(16384);
			catch (Exception e) assert(false, "Failed to allocate directory watcher buffer.");
		} ();

		if (!triggerRead(handle, *slot)) {
			releaseRef(id);
			return WatcherID.invalid;
		}

		return id;
	}

	override void addRef(WatcherID descriptor)
	{
		m_core.m_handles[idToHandle(descriptor)].addRef();
	}

	override bool releaseRef(WatcherID descriptor)
	{
		auto handle = idToHandle(descriptor);
		return m_core.m_handles[handle].releaseRef(()nothrow{
			CloseHandle(handle);
			() @trusted {
				try theAllocator.dispose(m_core.m_handles[handle].watcher.buffer);
				catch (Exception e) assert(false, "Freeing directory watcher buffer failed.");
			} ();
			m_core.freeSlot(handle);
		});
	}

	private static nothrow extern(System)
	void onIOCompleted(DWORD dwError, DWORD cbTransferred, OVERLAPPED* overlapped)
	{
		import std.conv : to;

		auto handle = overlapped.hEvent; // *file* handle
		auto id = WatcherID(cast(int)handle);
		auto slot = () @trusted { return &WinAPIEventDriver.threadInstance.core.m_handles[handle].watcher(); } ();

		if (dwError != 0) {
			// FIXME: this must be propagated to the caller
			//logWarn("Failed to read directory changes: %s", dwError);
			return;
		}

		ubyte[] result = slot.buffer[0 .. cbTransferred];
		do {
			assert(result.length >= FILE_NOTIFY_INFORMATION.sizeof);
			auto fni = () @trusted { return cast(FILE_NOTIFY_INFORMATION*)result.ptr; } ();
			FileChange ch;
			switch (fni.Action) {
				default: ch.kind = FileChangeKind.modified; break;
				case 0x1: ch.kind = FileChangeKind.added; break;
				case 0x2: ch.kind = FileChangeKind.removed; break;
				case 0x3: ch.kind = FileChangeKind.modified; break;
				case 0x4: ch.kind = FileChangeKind.removed; break;
				case 0x5: ch.kind = FileChangeKind.added; break;
			}
			ch.directory = slot.directory;
			ch.isDirectory = false; // FIXME: is this right?
			ch.name = () @trusted { scope (failure) assert(false); return to!string(fni.FileName[0 .. fni.FileNameLength/2]); } ();
			slot.callback(id, ch);
			if (fni.NextEntryOffset == 0) break;
			result = result[fni.NextEntryOffset .. $];
		} while (result.length > 0);

		triggerRead(handle, *slot);
	}

	private static bool triggerRead(HANDLE handle, ref WatcherSlot slot)
	{
		enum UINT notifications = FILE_NOTIFY_CHANGE_FILE_NAME|
			FILE_NOTIFY_CHANGE_DIR_NAME|FILE_NOTIFY_CHANGE_SIZE|
			FILE_NOTIFY_CHANGE_LAST_WRITE;

		slot.overlapped.Internal = 0;
		slot.overlapped.InternalHigh = 0;
		slot.overlapped.Offset = 0;
		slot.overlapped.OffsetHigh = 0;
		slot.overlapped.hEvent = handle;

		BOOL ret;
		() @trusted {
			ret = ReadDirectoryChangesW(handle, slot.buffer.ptr, cast(DWORD)slot.buffer.length, slot.recursive,
				notifications, null, &slot.overlapped, &onIOCompleted);
		} ();

		if (!ret) {
			//logError("Failed to read directory changes in '%s'", m_path);
			return false;
		}
		return true;
	}

	static private HANDLE idToHandle(WatcherID id) @trusted { return cast(HANDLE)cast(int)id; }
}

private long currStdTime()
@safe nothrow {
	import std.datetime : Clock;
	scope (failure) assert(false);
	return Clock.currStdTime;
}

private struct HandleSlot {
	static union SpecificTypes {
		typeof(null) none;
		FileSlot files;
		WatcherSlot watcher;
	}
	int refCount;
	TaggedAlgebraic!SpecificTypes specific;

	@safe nothrow:

	@property ref FileSlot file() { return specific.get!FileSlot; }
	@property ref WatcherSlot watcher() { return specific.get!WatcherSlot; }

	void addRef()
	{
		assert(refCount > 0);
		refCount++;
	}

	bool releaseRef(scope void delegate() @safe nothrow on_free)
	{
		assert(refCount > 0);
		if (--refCount == 0) {
			on_free();
			return false;
		}
		return true;
	}
}

private struct FileSlot {
	static struct Direction(bool RO) {
		OVERLAPPED overlapped;
		FileIOCallback callback;
		ulong offset;
		size_t bytesTransferred;
		IOMode mode;
		static if (RO) const(ubyte)[] buffer;
		else ubyte[] buffer;
		HANDLE handle; // set to INVALID_HANDLE_VALUE when closed

		void invokeCallback(IOStatus status, size_t bytes_transferred)
		@safe nothrow {
			auto cb = this.callback;
			this.callback = null;
			assert(cb !is null);
			cb(FileFD(cast(int)this.handle), status, bytes_transferred);
		}
	}
	Direction!false read;
	Direction!true write;
}

private struct WatcherSlot {
	ubyte[] buffer;
	OVERLAPPED overlapped;
	string directory;
	bool recursive;
	FileChangesCallback callback;
}

private extern(Windows) @trusted nothrow @nogc {
	BOOL SetEndOfFile(HANDLE hFile);
	BOOL CancelIoEx(HANDLE hFile, OVERLAPPED* lpOverlapped);
}
