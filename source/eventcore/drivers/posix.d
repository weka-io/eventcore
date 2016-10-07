/**
	Base class for BSD socket based driver implementations.

	See_also: `eventcore.drivers.select`, `eventcore.drivers.epoll`
*/
module eventcore.drivers.posix;
@safe: /*@nogc:*/ nothrow:

public import eventcore.driver;
import eventcore.drivers.timer;
import eventcore.drivers.threadedfile;
import eventcore.internal.consumablequeue : ConsumableQueue;
import eventcore.internal.utils;

import std.socket : Address, AddressFamily, UnknownAddress;
version (Posix) {
	import core.sys.posix.netinet.in_;
	import core.sys.posix.netinet.tcp;
	import core.sys.posix.unistd : close, read, write;
	import core.stdc.errno : errno, EAGAIN, EINPROGRESS;
	import core.sys.posix.fcntl;
}
version (Windows) {
	import core.sys.windows.winsock2;
	alias EAGAIN = WSAEWOULDBLOCK;
}
version (linux) {
	extern (C) int eventfd(uint initval, int flags);
	enum EFD_NONBLOCK = 0x800;
}


private long currStdTime()
{
	import std.datetime : Clock;
	scope (failure) assert(false);
	return Clock.currStdTime;
}

abstract class PosixEventDriver : EventDriver,
		EventDriverCore, EventDriverSockets, EventDriverTimers,
		EventDriverEvents, EventDriverSignals, EventDriverWatchers
{
@safe: /*@nogc:*/ nothrow:

	private {
		ChoppedVector!FDSlot m_fds;
		size_t m_waiterCount = 0;
		bool m_exit = false;
		FD m_wakeupEvent;
		ThreadedFileEventDriver!PosixEventDriver m_files;
	}

	protected this()
	{
		m_wakeupEvent = eventfd(0, EFD_NONBLOCK);
		initFD(m_wakeupEvent);
		registerFD(m_wakeupEvent, EventMask.read);
		//startNotify!(EventType.read)(m_wakeupEvent, null); // should already be caught by registerFD
		m_files = new ThreadedFileEventDriver!PosixEventDriver(this);
	}

	// force overriding these in the (final) sub classes to avoid virtual calls
	abstract override @property PosixEventDriver core();
	final override @property ThreadedFileEventDriver!PosixEventDriver files() { return m_files; }
	abstract override @property PosixEventDriver sockets();
	abstract override @property PosixEventDriver timers();
	abstract override @property PosixEventDriver events();
	abstract override @property PosixEventDriver signals();
	abstract override @property PosixEventDriver watchers();

	mixin DefaultTimerImpl!();

	protected int maxFD() const { return cast(int)m_fds.length; }

	@property size_t waiterCount() const { return m_waiterCount; }

	final override ExitReason processEvents(Duration timeout)
	{
		import std.algorithm : min;
		import core.time : seconds;

		if (m_exit) {
			m_exit = false;
			return ExitReason.exited;
		}

		if (!waiterCount) return ExitReason.outOfWaiters;

		bool got_events;

		if (timeout <= 0.seconds) {
			got_events = doProcessEvents(0.seconds);
			processTimers(currStdTime);
		} else {
			long now = currStdTime;
			do {
				auto nextto = min(getNextTimeout(now), timeout);
				got_events = doProcessEvents(nextto);
				long prev_step = now;
				now = currStdTime;
				got_events |= processTimers(now);
				if (timeout != Duration.max)
					timeout -= (now - prev_step).hnsecs;
			} while (timeout > 0.seconds && !m_exit && !got_events);
		}

		if (m_exit) {
			m_exit = false;
			return ExitReason.exited;
		}
		if (!waiterCount) return ExitReason.outOfWaiters;
		if (got_events) return ExitReason.idle;
		return ExitReason.timeout;
	}

	final override void exit()
	{
		m_exit = true;
		long one = 1;
		() @trusted { .write(m_wakeupEvent, &one, one.sizeof); } ();
	}

	final override void clearExitFlag()
	{
		m_exit = false;
	}

	protected abstract bool doProcessEvents(Duration dur);
	
	abstract void dispose()
	{
		m_files.dispose();
	}

	final override StreamSocketFD connectStream(scope Address address, ConnectCallback on_connect)
	{
		auto sock = cast(StreamSocketFD)createSocket(address.addressFamily, SOCK_STREAM);
		if (sock == -1) return StreamSocketFD.invalid;

		void invalidateSocket() @nogc @trusted nothrow { closeSocket(sock); sock = StreamSocketFD.invalid; }

		scope bind_addr = new UnknownAddress;
		bind_addr.name.sa_family = cast(ushort)address.addressFamily;
		bind_addr.name.sa_data[] = 0;
		if (() @trusted { return bind(sock, bind_addr.name, bind_addr.nameLen); } () != 0) {
			invalidateSocket();
			on_connect(sock, ConnectStatus.bindFailure);
			return sock;
		}

		registerFD(sock, EventMask.read|EventMask.write|EventMask.status);

		initFD(sock);

		auto ret = () @trusted { return connect(sock, address.name, address.nameLen); } ();
		if (ret == 0) {
			on_connect(sock, ConnectStatus.connected);
		} else {
			auto err = getSocketError();
			if (err == EINPROGRESS) {
				with (m_fds[sock]) {
					connectCallback = on_connect;
				}
				startNotify!(EventType.write)(sock, &onConnect);
			} else {
				clearFD(sock);
				unregisterFD(sock);
				invalidateSocket();
				on_connect(sock, ConnectStatus.unknownError);
				return sock;
			}
		}

		return sock;
	}

	private void onConnect(FD sock)
	{
		m_fds[sock].connectCallback(cast(StreamSocketFD)sock, ConnectStatus.connected);
	}

	private void onConnectError(FD sock)
	{
		// FIXME: determine the correct kind of error!
		m_fds[sock].connectCallback(cast(StreamSocketFD)sock, ConnectStatus.refused);
	}

	final override StreamListenSocketFD listenStream(scope Address address, AcceptCallback on_accept)
	{
		log("Listen stream");
		auto sock = cast(StreamListenSocketFD)createSocket(address.addressFamily, SOCK_STREAM);

		void invalidateSocket() @nogc @trusted nothrow { closeSocket(sock); sock = StreamSocketFD.invalid; }

		() @trusted {
			int tmp_reuse = 1;
			// FIXME: error handling!
			if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &tmp_reuse, tmp_reuse.sizeof) != 0) {
				log("setsockopt failed.");
				invalidateSocket();
			} else if (bind(sock, address.name, address.nameLen) != 0) {
				log("bind failed.");
				invalidateSocket();
			} else if (listen(sock, 128) != 0) {
				log("listen failed.");
				invalidateSocket();
			} else log("Success!");
		} ();

		if (sock == StreamListenSocketFD.invalid)
			return sock;

		initFD(sock);

		if (on_accept) waitForConnections(sock, on_accept);

		return sock;
	}

	final override void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept)
	{
		log("wait for conn");
		registerFD(sock, EventMask.read);
		m_fds[sock].acceptCallback = on_accept;
		startNotify!(EventType.read)(sock, &onAccept);
		onAccept(sock);
	}

	private void onAccept(FD listenfd)
	{
		scope addr = new UnknownAddress;
		foreach (i; 0 .. 20) {
			int sockfd;
			version (Windows) int addr_len = addr.nameLen;
			else uint addr_len = addr.nameLen;
			() @trusted { sockfd = accept(listenfd, addr.name, &addr_len); } ();
			if (sockfd == -1) break;

			setSocketNonBlocking(cast(SocketFD)sockfd);
			auto fd = cast(StreamSocketFD)sockfd;
			registerFD(fd, EventMask.read|EventMask.write|EventMask.status);
			initFD(fd);
			//print("accept %d", sockfd);
			m_fds[listenfd].acceptCallback(cast(StreamListenSocketFD)listenfd, fd);
		}
	}

	ConnectionState getConnectionState(StreamSocketFD sock)
	{
		assert(false);
	}

	final override void setTCPNoDelay(StreamSocketFD socket, bool enable)
	{
		int opt = enable;
		() @trusted { setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, cast(char*)&opt, opt.sizeof); } ();
	}

	final override void read(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish)
	{
		if (buffer.length == 0) {
			on_read_finish(socket, IOStatus.ok, 0);
			return;
		}

		sizediff_t ret;
		() @trusted { ret = .recv(socket, buffer.ptr, buffer.length, 0); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				print("sock error %s!", err);
				on_read_finish(socket, IOStatus.error, 0);
				return;
			}
		}

		if (ret == 0) {
			on_read_finish(socket, IOStatus.disconnected, 0);
			return;
		}

		if (ret < 0 && mode == IOMode.immediate) {
			on_read_finish(socket, IOStatus.wouldBlock, 0);
			return;
		}

		if (ret > 0) {
			buffer = buffer[ret .. $];
			if (mode != IOMode.all || buffer.length == 0) {
				on_read_finish(socket, IOStatus.ok, ret);
				return;
			}
		}

		with (m_fds[socket]) {
			readCallback = on_read_finish;
			readMode = mode;
			bytesRead = ret > 0 ? ret : 0;
			readBuffer = buffer;
		}

		setNotifyCallback!(EventType.read)(socket, &onSocketRead);
	}

	override void cancelRead(StreamSocketFD socket)
	{
		assert(m_fds[socket].readCallback !is null, "Cancelling read when there is no read in progress.");
		setNotifyCallback!(EventType.read)(socket, null);
		with (m_fds[socket]) {
			readBuffer = null;
		}
	}

	private void onSocketRead(FD fd)
	{
		auto slot = &m_fds[fd];
		auto socket = cast(StreamSocketFD)fd;

		void finalize()(IOStatus status)
		{
			setNotifyCallback!(EventType.read)(socket, null);
			//m_fds[fd].readBuffer = null;
			slot.readCallback(socket, status, slot.bytesRead);
		}

		sizediff_t ret;
		() @trusted { ret = .recv(socket, slot.readBuffer.ptr, slot.readBuffer.length, 0); } ();
		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				finalize(IOStatus.error);
				return;
			}
		}

		if (ret == 0) {
			finalize(IOStatus.disconnected);
			return;
		}

		if (ret > 0) {
			slot.bytesRead += ret;
			slot.readBuffer = slot.readBuffer[ret .. $];
			if (slot.readMode != IOMode.all || slot.readBuffer.length == 0) {
				finalize(IOStatus.ok);
				return;
			}
		}
	}

	final override void write(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish)
	{
		if (buffer.length == 0) {
			on_write_finish(socket, IOStatus.ok, 0);
			return;
		}

		sizediff_t ret;
		() @trusted { ret = .send(socket, buffer.ptr, buffer.length, 0); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				on_write_finish(socket, IOStatus.error, 0);
				return;
			}
		}

		size_t bytes_written = 0;

		if (ret == 0) {
			on_write_finish(socket, IOStatus.disconnected, 0);
			return;
		}

		if (ret < 0 && mode == IOMode.immediate) {
			on_write_finish(socket, IOStatus.wouldBlock, 0);
			return;
		}

		if (ret > 0) {
			bytes_written += ret;
			buffer = buffer[ret .. $];
			if (mode != IOMode.all || buffer.length == 0) {
				on_write_finish(socket, IOStatus.ok, bytes_written);
				return;
			}
		}

		with (m_fds[socket]) {
			writeCallback = on_write_finish;
			writeMode = mode;
			bytesWritten = ret > 0 ? ret : 0;
			writeBuffer = buffer;
		}

		setNotifyCallback!(EventType.write)(socket, &onSocketWrite);
	}

	override void cancelWrite(StreamSocketFD socket)
	{
		assert(m_fds[socket].writeCallback !is null, "Cancelling write when there is no write in progress.");
		setNotifyCallback!(EventType.write)(socket, null);
		m_fds[socket].writeBuffer = null;
	}

	private void onSocketWrite(FD fd)
	{
		auto slot = &m_fds[fd];
		auto socket = cast(StreamSocketFD)fd;

		sizediff_t ret;
		() @trusted { ret = .send(socket, slot.writeBuffer.ptr, slot.writeBuffer.length, 0); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				setNotifyCallback!(EventType.write)(socket, null);
				slot.writeCallback(socket, IOStatus.error, slot.bytesRead);
				return;
			}
		}

		if (ret == 0) {
			setNotifyCallback!(EventType.write)(socket, null);
			slot.writeCallback(cast(StreamSocketFD)socket, IOStatus.disconnected, slot.bytesWritten);
			return;
		}

		if (ret > 0) {
			slot.bytesWritten += ret;
			slot.writeBuffer = slot.writeBuffer[ret .. $];
			if (slot.writeMode != IOMode.all || slot.writeBuffer.length == 0) {
				setNotifyCallback!(EventType.write)(socket, null);
				slot.writeCallback(cast(StreamSocketFD)socket, IOStatus.ok, slot.bytesWritten);
				return;
			}
		}
	}

	final override void waitForData(StreamSocketFD socket, IOCallback on_data_available)
	{
		sizediff_t ret;
		ubyte dummy;
		() @trusted { ret = recv(socket, &dummy, 1, MSG_PEEK); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				on_data_available(socket, IOStatus.error, 0);
				return;
			}
		}

		size_t bytes_read = 0;

		if (ret == 0) {
			on_data_available(socket, IOStatus.disconnected, 0);
			return;
		}

		if (ret > 0) {
			on_data_available(socket, IOStatus.ok, 0);
			return;
		}

		with (m_fds[socket]) {
			readCallback = on_data_available;
			readMode = IOMode.once;
			bytesRead = 0;
			readBuffer = null;
		}

		setNotifyCallback!(EventType.read)(socket, &onSocketDataAvailable);
	}

	private void onSocketDataAvailable(FD fd)
	{
		auto slot = &m_fds[fd];
		auto socket = cast(StreamSocketFD)fd;

		void finalize()(IOStatus status)
		{
			setNotifyCallback!(EventType.read)(socket, null);
			//m_fds[fd].readBuffer = null;
			slot.readCallback(socket, status, 0);
		}

		sizediff_t ret;
		ubyte tmp;
		() @trusted { ret = recv(socket, &tmp, 1, MSG_PEEK); } ();
		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) finalize(IOStatus.error);
		} else finalize(ret ? IOStatus.ok : IOStatus.disconnected);
	}

	final override void shutdown(StreamSocketFD socket, bool shut_read, bool shut_write)
	{
		// TODO!
	}

	DatagramSocketFD createDatagramSocket(scope Address bind_address, scope Address target_address)
	{
		auto sock = cast(DatagramSocketFD)createSocket(bind_address.addressFamily, SOCK_DGRAM);
		if (sock == -1) return DatagramSocketFD.invalid;

		if (bind_address && () @trusted { return bind(sock, bind_address.name, bind_address.nameLen); } () != 0) {
			closeSocket(sock);
			return DatagramSocketFD.init;
		}

		if (target_address && () @trusted { return connect(sock, target_address.name, target_address.nameLen); } () != 0) {
			closeSocket(sock);
			return DatagramSocketFD.init;
		}

		registerFD(sock, EventMask.read|EventMask.write|EventMask.status);

		initFD(sock);

		return sock;
	}

	void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_receive_finish)
	{
		assert(mode != IOMode.all, "Only IOMode.immediate and IOMode.once allowed for datagram sockets.");

		sizediff_t ret;
		scope src_addr = new UnknownAddress;
		socklen_t src_addr_len = src_addr.nameLen;
		() @trusted { ret = .recvfrom(socket, buffer.ptr, buffer.length, 0, src_addr.name, &src_addr_len); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				print("sock error %s!", err);
				on_receive_finish(socket, IOStatus.error, 0, null);
				return;
			}

			if (mode == IOMode.immediate) {
				on_receive_finish(socket, IOStatus.wouldBlock, 0, null);
			} else {
				with (m_fds[socket]) {
					readCallback = () @trusted { return cast(IOCallback)on_receive_finish; } ();
					readMode = mode;
					bytesRead = 0;
					readBuffer = buffer;
				}

				setNotifyCallback!(EventType.read)(socket, &onDgramRead);
			}
			return;
		}

		on_receive_finish(socket, IOStatus.ok, ret, src_addr);
	}

	void cancelReceive(DatagramSocketFD socket)
	{
		assert(m_fds[socket].readCallback !is null, "Cancelling read when there is no read in progress.");
		setNotifyCallback!(EventType.read)(socket, null);
		m_fds[socket].readBuffer = null;
	}

	private void onDgramRead(FD fd)
	{
		auto slot = &m_fds[fd];
		auto socket = cast(DatagramSocketFD)fd;

		sizediff_t ret;
		scope src_addr = new UnknownAddress;
		socklen_t src_addr_len = src_addr.nameLen;
		() @trusted { ret = .recvfrom(socket, slot.readBuffer.ptr, slot.readBuffer.length, 0, src_addr.name, &src_addr_len); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				setNotifyCallback!(EventType.read)(socket, null);
				() @trusted { return cast(DatagramIOCallback)slot.readCallback; } ()(socket, IOStatus.error, 0, null);
				return;
			}
		}

		setNotifyCallback!(EventType.read)(socket, null);
		() @trusted { return cast(DatagramIOCallback)slot.readCallback; } ()(socket, IOStatus.ok, ret, src_addr);
	}

	void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, DatagramIOCallback on_send_finish, Address target_address = null)
	{
		assert(mode != IOMode.all, "Only IOMode.immediate and IOMode.once allowed for datagram sockets.");

		sizediff_t ret;
		if (target_address) {
			() @trusted { ret = .sendto(socket, buffer.ptr, buffer.length, 0, target_address.name, target_address.nameLen); } ();
			m_fds[socket].targetAddr = target_address;
		} else {
			() @trusted { ret = .send(socket, buffer.ptr, buffer.length, 0); } ();
		}

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				print("sock error %s!", err);
				on_send_finish(socket, IOStatus.error, 0, null);
				return;
			}

			if (mode == IOMode.immediate) {
				on_send_finish(socket, IOStatus.wouldBlock, 0, null);
			} else {
				with (m_fds[socket]) {
					writeCallback = () @trusted { return cast(IOCallback)on_send_finish; } ();
					writeMode = mode;
					bytesWritten = 0;
					writeBuffer = buffer;
				}

				setNotifyCallback!(EventType.write)(socket, &onDgramWrite);
			}
			return;
		}

		on_send_finish(socket, IOStatus.ok, ret, null);
	}

	void cancelSend(DatagramSocketFD socket)
	{
		assert(m_fds[socket].writeCallback !is null, "Cancelling write when there is no write in progress.");
		setNotifyCallback!(EventType.write)(socket, null);
		m_fds[socket].writeBuffer = null;
	}

	private void onDgramWrite(FD fd)
	{
		auto slot = &m_fds[fd];
		auto socket = cast(DatagramSocketFD)fd;

		sizediff_t ret;
		if (slot.targetAddr) {
			() @trusted { ret = .sendto(socket, slot.writeBuffer.ptr, slot.writeBuffer.length, 0, slot.targetAddr.name, slot.targetAddr.nameLen); } ();
		} else {
			() @trusted { ret = .send(socket, slot.writeBuffer.ptr, slot.writeBuffer.length, 0); } ();
		}

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				setNotifyCallback!(EventType.write)(socket, null);
				() @trusted { return cast(DatagramIOCallback)slot.writeCallback; } ()(socket, IOStatus.error, 0, null);
				return;
			}
		}

		setNotifyCallback!(EventType.write)(socket, null);
		() @trusted { return cast(DatagramIOCallback)slot.writeCallback; } ()(socket, IOStatus.ok, ret, null);
	}

	final override void addRef(SocketFD fd)
	{
		auto pfd = &m_fds[fd];
		assert(pfd.refCount > 0, "Adding reference to unreferenced socket FD.");
		m_fds[fd].refCount++;
	}

	final override void releaseRef(SocketFD fd)
	{
		auto pfd = &m_fds[fd];
		assert(pfd.refCount > 0, "Releasing reference to unreferenced socket FD.");
		if (--m_fds[fd].refCount == 0) {
			unregisterFD(fd);
			clearFD(fd);
			closeSocket(fd);
		}
	}

	final override EventID create()
	{
		auto id = cast(EventID)eventfd(0, EFD_NONBLOCK);
		initFD(id);
		m_fds[id].waiters = new ConsumableQueue!EventCallback; // FIXME: avoid dynamic memory allocation
		registerFD(id, EventMask.read);
		startNotify!(EventType.read)(id, &onEvent);
		return id;
	}

	final override void trigger(EventID event, bool notify_all = true)
	{
		assert(event < m_fds.length, "Invalid event ID passed to triggerEvent.");
		if (notify_all) {
			//log("emitting only for this thread (%s waiters)", m_fds[event].waiters.length);
			foreach (w; m_fds[event].waiters.consume) {
				//log("emitting waiter %s %s", cast(void*)w.funcptr, w.ptr);
				w(event);
			}
		} else {
			if (!m_fds[event].waiters.empty)
				m_fds[event].waiters.consumeOne();
		}
	}

	final override void trigger(EventID event, bool notify_all = true)
	shared @trusted {
		import core.atomic : atomicStore;
		auto thisus = cast(PosixEventDriver)this;
		assert(event < thisus.m_fds.length, "Invalid event ID passed to shared triggerEvent.");
		long one = 1;
		//log("emitting for all threads");
		if (notify_all) atomicStore(thisus.m_fds[event].triggerAll, true);
		() @trusted { .write(event, &one, one.sizeof); } ();
	}

	final override void wait(EventID event, EventCallback on_event)
	{
		assert(event < m_fds.length, "Invalid event ID passed to waitForEvent.");
		return m_fds[event].waiters.put(on_event);
	}

	final override void cancelWait(EventID event, EventCallback on_event)
	{
		import std.algorithm.searching : countUntil;
		import std.algorithm.mutation : remove;

		auto slot = &m_fds[event];
		slot.waiters.removePending(on_event);
	}

	private void onEvent(FD event)
	@trusted {
		ulong cnt;
		() @trusted { .read(event, &cnt, cnt.sizeof); } ();
		import core.atomic : cas;
		auto all = cas(&m_fds[event].triggerAll, true, false);
		trigger(cast(EventID)event, all);
	}

	final override void addRef(EventID descriptor)
	{
		auto pfd = &m_fds[descriptor];
		assert(pfd.refCount > 0, "Adding reference to unreferenced event FD.");
		m_fds[descriptor].refCount++;
	}

	final override void releaseRef(EventID descriptor)
	{
		auto pfd = &m_fds[descriptor];
		assert(pfd.refCount > 0, "Releasing reference to unreferenced event FD.");
		if (--m_fds[descriptor].refCount == 0) {
			unregisterFD(descriptor);
			clearFD(descriptor);
			close(descriptor);
		}
	}
	

	final override void wait(int sig, SignalCallback on_signal)
	{
		assert(false, "TODO!");
	}

	final override void cancelWait(int sig)
	{
		assert(false, "TODO!");
	}

	final override WatcherID watchDirectory(string path, bool recursive)
	{
		assert(false, "TODO!");
	}

	final override void wait(WatcherID watcher, FileChangesCallback callback)
	{
		assert(false, "TODO!");
	}

	final override void cancelWait(WatcherID watcher)
	{
		assert(false, "TODO!");
	}

	final override void addRef(WatcherID descriptor)
	{
		assert(false, "TODO!");
	}

	final override void releaseRef(WatcherID descriptor)
	{
		assert(false, "TODO!");
	}

	final override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		FDSlot* fds = &m_fds[descriptor];
		assert(fds.userDataDestructor is null || fds.userDataDestructor is destroy,
			"Requesting user data with differing type (destructor).");
		assert(size <= FDSlot.userData.length, "Requested user data is too large.");
		if (size > FDSlot.userData.length) assert(false);
		if (!fds.userDataDestructor) {
			initialize(fds.userData.ptr);
			fds.userDataDestructor = destroy;
		}
		return m_fds[descriptor].userData.ptr;
	}


	/// Registers the FD for general notification reception.
	protected abstract void registerFD(FD fd, EventMask mask);
	/// Unregisters the FD for general notification reception.
	protected abstract void unregisterFD(FD fd);
	/// Updates the event mask to use for listening for notifications.
	protected abstract void updateFD(FD fd, EventMask mask);

	final protected void enumerateFDs(EventType evt)(scope FDEnumerateCallback del)
	{
		// TODO: optimize!
		foreach (i; 0 .. cast(int)m_fds.length)
			if (m_fds[i].callback[evt])
				del(cast(FD)i);
	}

	final protected void notify(EventType evt)(FD fd)
	{
		//assert(m_fds[fd].callback[evt] !is null, "Notifying FD which is not listening for event.");
		if (m_fds[fd].callback[evt])
			m_fds[fd].callback[evt](fd);
	}

	private void startNotify(EventType evt)(FD fd, FDSlotCallback callback)
	{
		//log("start notify %s %s", evt, fd);
		//assert(m_fds[fd].callback[evt] is null, "Waiting for event which is already being waited for.");
		m_fds[fd].callback[evt] = callback;
		m_waiterCount++;
		updateFD(fd, m_fds[fd].eventMask);
	}

	private void stopNotify(EventType evt)(FD fd)
	{
		//log("stop notify %s %s", evt, fd);
		//ssert(m_fds[fd].callback[evt] !is null, "Stopping waiting for event which is not being waited for.");
		m_fds[fd].callback[evt] = null;
		m_waiterCount--;
		updateFD(fd, m_fds[fd].eventMask);
	}

	private void setNotifyCallback(EventType evt)(FD fd, FDSlotCallback callback)
	{
		assert((callback !is null) != (m_fds[fd].callback[evt] !is null),
			"Overwriting notification callback.");
		m_fds[fd].callback[evt] = callback;
	}

	private SocketFD createSocket(AddressFamily family, int type)
	{
		int sock;
		() @trusted { sock = socket(family, type, 0); } ();
		if (sock == -1) return SocketFD.invalid;
		setSocketNonBlocking(cast(SocketFD)sock);
		return cast(SocketFD)sock;
	}

	private void initFD(FD fd)
	{
		m_fds[fd].refCount = 1;
	}

	private void clearFD(FD fd)
	{
		if (m_fds[fd].userDataDestructor)
			() @trusted { m_fds[fd].userDataDestructor(m_fds[fd].userData.ptr); } ();
		() @trusted nothrow {
			scope (failure) assert(false);
			destroy(m_fds[fd].waiters);
		} ();
		m_fds[fd] = FDSlot.init;
	}
}

alias FDEnumerateCallback = void delegate(FD);

alias FDSlotCallback = void delegate(FD);

private struct FDSlot {
	FDSlotCallback[EventType.max+1] callback;

	uint refCount;

	size_t bytesRead;
	ubyte[] readBuffer;
	IOMode readMode;
	IOCallback readCallback; // FIXME: this type only works for stream sockets

	size_t bytesWritten;
	const(ubyte)[] writeBuffer;
	IOMode writeMode;
	IOCallback writeCallback; // FIXME: this type only works for stream sockets
	Address targetAddr;

	ConnectCallback connectCallback;
	AcceptCallback acceptCallback;
	ConsumableQueue!EventCallback waiters;

	DataInitializer userDataDestructor;
	ubyte[16*size_t.sizeof] userData;

	shared bool triggerAll;

	@property EventMask eventMask() const nothrow {
		EventMask ret = cast(EventMask)0;
		if (callback[EventType.read] !is null) ret |= EventMask.read;
		if (callback[EventType.write] !is null) ret |= EventMask.write;
		if (callback[EventType.status] !is null) ret |= EventMask.status;
		return ret;
	}
}

enum EventType {
	read,
	write,
	status
}

enum EventMask {
	read = 1<<0,
	write = 1<<1,
	status = 1<<2
}

private void closeSocket(SocketFD sockfd)
@nogc {
	version (Windows) () @trusted { closesocket(sockfd); } ();
	else close(sockfd);
}

private void setSocketNonBlocking(SocketFD sockfd)
{
	version (Windows) {
		size_t enable = 1;
		() @trusted { ioctlsocket(sockfd, FIONBIO, &enable); } ();
	} else {
		() @trusted { fcntl(sockfd, F_SETFL, O_NONBLOCK, 1); } ();
	}
}

private int getSocketError()
@nogc {
	version (Windows) return WSAGetLastError();
	else return errno;
}

void log(ARGS...)(string fmt, ARGS args)
{
	import std.stdio;
	try writefln(fmt, args);
	catch (Exception) {}
}


/*version (Windows) {
	import std.c.windows.windows;
	import std.c.windows.winsock;

	alias EWOULDBLOCK = WSAEWOULDBLOCK;

	extern(System) DWORD FormatMessageW(DWORD dwFlags, const(void)* lpSource, DWORD dwMessageId, DWORD dwLanguageId, LPWSTR lpBuffer, DWORD nSize, void* Arguments);

	class WSAErrorException : Exception {
		int error;

		this(string message, string file = __FILE__, size_t line = __LINE__)
		{
			error = WSAGetLastError();
			this(message, error, file, line);
		}

		this(string message, int error, string file = __FILE__, size_t line = __LINE__)
		{
			import std.string : format;
			ushort* errmsg;
			FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER|FORMAT_MESSAGE_FROM_SYSTEM|FORMAT_MESSAGE_IGNORE_INSERTS,
						   null, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), cast(LPWSTR)&errmsg, 0, null);
			size_t len = 0;
			while (errmsg[len]) len++;
			auto errmsgd = (cast(wchar[])errmsg[0 .. len]).idup;
			LocalFree(errmsg);
			super(format("%s: %s (%s)", message, errmsgd, error), file, line);
		}
	}

	alias SystemSocketException = WSAErrorException;
} else {
	import std.exception : ErrnoException;
	alias SystemSocketException = ErrnoException;
}

T socketEnforce(T)(T value, lazy string msg = null, string file = __FILE__, size_t line = __LINE__)
{
	import std.exception : enforceEx;
	return enforceEx!SystemSocketException(value, msg, file, line);
}*/
