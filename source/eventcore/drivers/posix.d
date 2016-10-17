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

import std.socket : Address, AddressFamily, InternetAddress, Internet6Address, UnixAddress, UnknownAddress;
version (Posix) {
	import core.sys.posix.netdb : AI_ADDRCONFIG, AI_V4MAPPED, addrinfo, freeaddrinfo, getaddrinfo;
	import core.sys.posix.netinet.in_;
	import core.sys.posix.netinet.tcp;
	import core.sys.posix.sys.un;
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

final class PosixEventDriver(Loop : PosixEventLoop) : EventDriver {
@safe: /*@nogc:*/ nothrow:


	private {
		alias CoreDriver = PosixEventDriverCore!(Loop, LoopTimeoutTimerDriver);
		alias EventsDriver = PosixEventDriverEvents!Loop;
		alias SignalsDriver = PosixEventDriverSignals!Loop;
		alias TimerDriver = LoopTimeoutTimerDriver;
		alias SocketsDriver = PosixEventDriverSockets!Loop;
		version (linux) alias DNSDriver = EventDriverDNS_GAIA!(EventsDriver, SignalsDriver);
		else alias DNSDriver = EventDriverDNS_GAI!(EventsDriver, SignalsDriver);
		alias FileDriver = ThreadedFileEventDriver!EventsDriver;
		version (linux) alias WatcherDriver = InotifyEventDriverWatchers!Loop;
		else alias WatcherDriver = PosixEventDriverWatchers!Loop;

		Loop m_loop;
		CoreDriver m_core;
		EventsDriver m_events;
		SignalsDriver m_signals;
		LoopTimeoutTimerDriver m_timers;
		SocketsDriver m_sockets;
		DNSDriver m_dns;
		FileDriver m_files;
		WatcherDriver m_watchers;
	}

	this()
	{
		m_loop = new Loop;
		m_events = new EventsDriver(m_loop);
		m_signals = new SignalsDriver(m_loop);
		m_timers = new TimerDriver;
		m_core = new CoreDriver(m_loop, m_timers);
		m_sockets = new SocketsDriver(m_loop);
		m_dns = new DNSDriver(m_events, m_signals);
		m_files = new FileDriver(m_events);
		m_watchers = new WatcherDriver(m_loop);
	}

	// force overriding these in the (final) sub classes to avoid virtual calls
	final override @property CoreDriver core() { return m_core; }
	final override @property EventsDriver events() { return m_events; }
	final override @property SignalsDriver signals() { return m_signals; }
	final override @property TimerDriver timers() { return m_timers; }
	final override @property SocketsDriver sockets() { return m_sockets; }
	final override @property DNSDriver dns() { return m_dns; }
	final override @property FileDriver files() { return m_files; }
	final override @property WatcherDriver watchers() { return m_watchers; }

	final override void dispose()
	{
		m_files.dispose();
		m_dns.dispose();
		m_loop.dispose();		
	}
}


final class PosixEventDriverCore(Loop : PosixEventLoop, Timers : EventDriverTimers) : EventDriverCore {
@safe: nothrow:
	import core.time : Duration;

	protected alias ExtraEventsCallback = bool delegate(long);

	private {
		Loop m_loop;
		Timers m_timers;
		bool m_exit = false;
		FD m_wakeupEvent;
	}

	protected this(Loop loop, Timers timers)
	{
		m_loop = loop;
		m_timers = timers;

		m_wakeupEvent = eventfd(0, EFD_NONBLOCK);
		m_loop.initFD(m_wakeupEvent);
		m_loop.registerFD(m_wakeupEvent, EventMask.read);
		//startNotify!(EventType.read)(m_wakeupEvent, null); // should already be caught by registerFD
	}

	@property size_t waiterCount() const { return m_loop.m_waiterCount; }

	final override ExitReason processEvents(Duration timeout)
	{
		import std.algorithm : min;
		import core.time : hnsecs, seconds;

		if (m_exit) {
			m_exit = false;
			return ExitReason.exited;
		}

		if (!waiterCount) return ExitReason.outOfWaiters;

		bool got_events;

		if (timeout <= 0.seconds) {
			got_events = m_loop.doProcessEvents(0.seconds);
			m_timers.process(currStdTime);
		} else {
			long now = currStdTime;
			do {
				auto nextto = min(m_timers.getNextTimeout(now), timeout);
				got_events = m_loop.doProcessEvents(nextto);
				long prev_step = now;
				now = currStdTime;
				got_events |= m_timers.process(now);
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

	final protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		FDSlot* fds = &m_loop.m_fds[descriptor];
		assert(fds.userDataDestructor is null || fds.userDataDestructor is destroy,
			"Requesting user data with differing type (destructor).");
		assert(size <= FDSlot.userData.length, "Requested user data is too large.");
		if (size > FDSlot.userData.length) assert(false);
		if (!fds.userDataDestructor) {
			initialize(fds.userData.ptr);
			fds.userDataDestructor = destroy;
		}
		return m_loop.m_fds[descriptor].userData.ptr;
	}
}


final class PosixEventDriverSockets(Loop : PosixEventLoop) : EventDriverSockets {
@safe: /*@nogc:*/ nothrow:
	private Loop m_loop;

	this(Loop loop) { m_loop = loop; }

	final override StreamSocketFD connectStream(scope Address address, ConnectCallback on_connect)
	{
		auto sock = cast(StreamSocketFD)createSocket(address.addressFamily, SOCK_STREAM);
		if (sock == -1) return StreamSocketFD.invalid;

		void invalidateSocket() @nogc @trusted nothrow { closeSocket(sock); sock = StreamSocketFD.invalid; }

		int bret;
		() @trusted { // scope
			scope bind_addr = new UnknownAddress;
			bind_addr.name.sa_family = cast(ushort)address.addressFamily;
			bind_addr.name.sa_data[] = 0;
			bret = bind(sock, bind_addr.name, bind_addr.nameLen);
		} ();
		if (bret != 0) {
			invalidateSocket();
			on_connect(sock, ConnectStatus.bindFailure);
			return sock;
		}

		m_loop.initFD(sock);
		m_loop.registerFD(sock, EventMask.read|EventMask.write|EventMask.status);

		auto ret = () @trusted { return connect(sock, address.name, address.nameLen); } ();
		if (ret == 0) {
			on_connect(sock, ConnectStatus.connected);
		} else {
			auto err = getSocketError();
			if (err == EINPROGRESS) {
				with (m_loop.m_fds[sock]) {
					connectCallback = on_connect;
				}
				m_loop.startNotify!(EventType.write)(sock, &onConnect);
			} else {
				m_loop.clearFD(sock);
				m_loop.unregisterFD(sock);
				invalidateSocket();
				on_connect(sock, ConnectStatus.unknownError);
				return sock;
			}
		}

		return sock;
	}

	private void onConnect(FD sock)
	{
		m_loop.setNotifyCallback!(EventType.write)(sock, null);
		m_loop.m_fds[sock].connectCallback(cast(StreamSocketFD)sock, ConnectStatus.connected);
	}

	private void onConnectError(FD sock)
	{
		// FIXME: determine the correct kind of error!
		m_loop.m_fds[sock].connectCallback(cast(StreamSocketFD)sock, ConnectStatus.refused);
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

		m_loop.initFD(sock);

		if (on_accept) waitForConnections(sock, on_accept);

		return sock;
	}

	final override void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept)
	{
		log("wait for conn");
		m_loop.registerFD(sock, EventMask.read);
		m_loop.m_fds[sock].acceptCallback = on_accept;
		m_loop.startNotify!(EventType.read)(sock, &onAccept);
		onAccept(sock);
	}

	private void onAccept(FD listenfd)
	{
		foreach (i; 0 .. 20) {
			int sockfd;
			sockaddr_storage addr;
			version (Windows) int addr_len = addr.sizeof;
			else uint addr_len = addr.sizeof;
			() @trusted { sockfd = accept(listenfd, () @trusted { return cast(sockaddr*)&addr; } (), &addr_len); } ();
			if (sockfd == -1) break;

			setSocketNonBlocking(cast(SocketFD)sockfd);
			auto fd = cast(StreamSocketFD)sockfd;
			m_loop.initFD(fd);
			m_loop.registerFD(fd, EventMask.read|EventMask.write|EventMask.status);
			//print("accept %d", sockfd);
			m_loop.m_fds[listenfd].acceptCallback(cast(StreamListenSocketFD)listenfd, fd);
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

		with (m_loop.m_fds[socket]) {
			readCallback = on_read_finish;
			readMode = mode;
			bytesRead = ret > 0 ? ret : 0;
			readBuffer = buffer;
		}

		m_loop.setNotifyCallback!(EventType.read)(socket, &onSocketRead);
	}

	override void cancelRead(StreamSocketFD socket)
	{
		assert(m_loop.m_fds[socket].readCallback !is null, "Cancelling read when there is no read in progress.");
		m_loop.setNotifyCallback!(EventType.read)(socket, null);
		with (m_loop.m_fds[socket]) {
			readBuffer = null;
		}
	}

	private void onSocketRead(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd]; } ();
		auto socket = cast(StreamSocketFD)fd;

		void finalize()(IOStatus status)
		{
			m_loop.setNotifyCallback!(EventType.read)(socket, null);
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

		with (m_loop.m_fds[socket]) {
			writeCallback = on_write_finish;
			writeMode = mode;
			bytesWritten = ret > 0 ? ret : 0;
			writeBuffer = buffer;
		}

		m_loop.setNotifyCallback!(EventType.write)(socket, &onSocketWrite);
	}

	override void cancelWrite(StreamSocketFD socket)
	{
		assert(m_loop.m_fds[socket].writeCallback !is null, "Cancelling write when there is no write in progress.");
		m_loop.setNotifyCallback!(EventType.write)(socket, null);
		m_loop.m_fds[socket].writeBuffer = null;
	}

	private void onSocketWrite(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd]; } ();
		auto socket = cast(StreamSocketFD)fd;

		sizediff_t ret;
		() @trusted { ret = .send(socket, slot.writeBuffer.ptr, slot.writeBuffer.length, 0); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				m_loop.setNotifyCallback!(EventType.write)(socket, null);
				slot.writeCallback(socket, IOStatus.error, slot.bytesRead);
				return;
			}
		}

		if (ret == 0) {
			m_loop.setNotifyCallback!(EventType.write)(socket, null);
			slot.writeCallback(cast(StreamSocketFD)socket, IOStatus.disconnected, slot.bytesWritten);
			return;
		}

		if (ret > 0) {
			slot.bytesWritten += ret;
			slot.writeBuffer = slot.writeBuffer[ret .. $];
			if (slot.writeMode != IOMode.all || slot.writeBuffer.length == 0) {
				m_loop.setNotifyCallback!(EventType.write)(socket, null);
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

		with (m_loop.m_fds[socket]) {
			readCallback = on_data_available;
			readMode = IOMode.once;
			bytesRead = 0;
			readBuffer = null;
		}

		m_loop.setNotifyCallback!(EventType.read)(socket, &onSocketDataAvailable);
	}

	private void onSocketDataAvailable(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd]; } ();
		auto socket = cast(StreamSocketFD)fd;

		void finalize()(IOStatus status)
		{
			m_loop.setNotifyCallback!(EventType.read)(socket, null);
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

		m_loop.initFD(sock);
		m_loop.registerFD(sock, EventMask.read|EventMask.write|EventMask.status);

		return sock;
	}

	void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_receive_finish)
	@trusted { // DMD 2.072.0-b2: scope considered unsafe
		import std.typecons : scoped;

		assert(mode != IOMode.all, "Only IOMode.immediate and IOMode.once allowed for datagram sockets.");

		sizediff_t ret;
		scope src_addr = new UnknownAddress();
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
				with (m_loop.m_fds[socket]) {
					readCallback = () @trusted { return cast(IOCallback)on_receive_finish; } ();
					readMode = mode;
					bytesRead = 0;
					readBuffer = buffer;
				}

				m_loop.setNotifyCallback!(EventType.read)(socket, &onDgramRead);
			}
			return;
		}

		on_receive_finish(socket, IOStatus.ok, ret, src_addr);
	}

	void cancelReceive(DatagramSocketFD socket)
	{
		assert(m_loop.m_fds[socket].readCallback !is null, "Cancelling read when there is no read in progress.");
		m_loop.setNotifyCallback!(EventType.read)(socket, null);
		m_loop.m_fds[socket].readBuffer = null;
	}

	private void onDgramRead(FD fd)
	@trusted { // DMD 2.072.0-b2: scope considered unsafe
		auto slot = () @trusted { return &m_loop.m_fds[fd]; } ();
		auto socket = cast(DatagramSocketFD)fd;

		sizediff_t ret;
		scope src_addr = new UnknownAddress;
		socklen_t src_addr_len = src_addr.nameLen;
		() @trusted { ret = .recvfrom(socket, slot.readBuffer.ptr, slot.readBuffer.length, 0, src_addr.name, &src_addr_len); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				m_loop.setNotifyCallback!(EventType.read)(socket, null);
				() @trusted { return cast(DatagramIOCallback)slot.readCallback; } ()(socket, IOStatus.error, 0, null);
				return;
			}
		}

		m_loop.setNotifyCallback!(EventType.read)(socket, null);
		() @trusted { return cast(DatagramIOCallback)slot.readCallback; } ()(socket, IOStatus.ok, ret, src_addr);
	}

	void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, DatagramIOCallback on_send_finish, Address target_address = null)
	{
		assert(mode != IOMode.all, "Only IOMode.immediate and IOMode.once allowed for datagram sockets.");

		sizediff_t ret;
		if (target_address) {
			() @trusted { ret = .sendto(socket, buffer.ptr, buffer.length, 0, target_address.name, target_address.nameLen); } ();
			m_loop.m_fds[socket].targetAddr = target_address;
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
				with (m_loop.m_fds[socket]) {
					writeCallback = () @trusted { return cast(IOCallback)on_send_finish; } ();
					writeMode = mode;
					bytesWritten = 0;
					writeBuffer = buffer;
				}

				m_loop.setNotifyCallback!(EventType.write)(socket, &onDgramWrite);
			}
			return;
		}

		on_send_finish(socket, IOStatus.ok, ret, null);
	}

	void cancelSend(DatagramSocketFD socket)
	{
		assert(m_loop.m_fds[socket].writeCallback !is null, "Cancelling write when there is no write in progress.");
		m_loop.setNotifyCallback!(EventType.write)(socket, null);
		m_loop.m_fds[socket].writeBuffer = null;
	}

	private void onDgramWrite(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd]; } ();
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
				m_loop.setNotifyCallback!(EventType.write)(socket, null);
				() @trusted { return cast(DatagramIOCallback)slot.writeCallback; } ()(socket, IOStatus.error, 0, null);
				return;
			}
		}

		m_loop.setNotifyCallback!(EventType.write)(socket, null);
		() @trusted { return cast(DatagramIOCallback)slot.writeCallback; } ()(socket, IOStatus.ok, ret, null);
	}

	final override void addRef(SocketFD fd)
	{
		auto pfd = () @trusted { return &m_loop.m_fds[fd]; } ();
		assert(pfd.refCount > 0, "Adding reference to unreferenced socket FD.");
		m_loop.m_fds[fd].refCount++;
	}

	final override bool releaseRef(SocketFD fd)
	{
		auto pfd = () @trusted { return &m_loop.m_fds[fd]; } ();
		assert(pfd.refCount > 0, "Releasing reference to unreferenced socket FD.");
		if (--m_loop.m_fds[fd].refCount == 0) {
			m_loop.unregisterFD(fd);
			m_loop.clearFD(fd);
			closeSocket(fd);
			return false;
		}
		return true;
	}

	private SocketFD createSocket(AddressFamily family, int type)
	{
		int sock;
		() @trusted { sock = socket(family, type, 0); } ();
		if (sock == -1) return SocketFD.invalid;
		setSocketNonBlocking(cast(SocketFD)sock);
		return cast(SocketFD)sock;
	}
}


/// getaddrinfo_a based asynchronous lookups
final class EventDriverDNS_GAI(Events : EventDriverEvents, Signals : EventDriverSignals) : EventDriverDNS {
	import std.parallelism : task, taskPool;
	import std.string : toStringz;

	private {
		static struct Lookup {
			DNSLookupCallback callback;
			addrinfo* result;
			int retcode;
			string name;
		}
		ChoppedVector!Lookup m_lookups;
		Events m_events;
		EventID m_event;
		size_t m_maxHandle;
	}

	this(Events events, Signals signals)
	{
		m_events = events;
		m_event = events.create();
		m_events.wait(m_event, &onDNSSignal);
	}

	void dispose()
	{
		m_events.cancelWait(m_event, &onDNSSignal);
		m_events.releaseRef(m_event);
	}

	override DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished)
	{
		auto handle = getFreeHandle();
		if (handle > m_maxHandle) m_maxHandle = handle;

		assert(!m_lookups[handle].result);
		Lookup* l = () @trusted { return &m_lookups[handle]; } ();
		l.name = name;
		l.callback = on_lookup_finished;
		auto events = () @trusted { return cast(shared)m_events; } ();
		auto t = task!taskFun(l, AddressFamily.UNSPEC, events, m_event);
		try taskPool.put(t);
		catch (Exception e) return DNSLookupID.invalid;
		return handle;
	}

	/// public
	static void taskFun(Lookup* lookup, int af, shared(Events) events, EventID event)
	{
		addrinfo hints;
		hints.ai_flags = AI_ADDRCONFIG|AI_V4MAPPED;
		hints.ai_family = af;
		() @trusted { lookup.retcode = getaddrinfo(lookup.name.toStringz(), null, af == AddressFamily.UNSPEC ? null : &hints, &lookup.result); } ();
		events.trigger(event);
	}

	override void cancelLookup(DNSLookupID handle)
	{
		m_lookups[handle].callback = null;
	}

	private void onDNSSignal(EventID event)
		@trusted nothrow
	{
		size_t lastmax;
		foreach (i, ref l; m_lookups) {
			if (i > m_maxHandle) break;
			if (l.callback) {
				if (l.result || l.retcode) {
					auto cb = l.callback;
					auto ai = l.result;
					DNSStatus status;
					switch (l.retcode) {
						default: status = DNSStatus.error; break;
						case 0: status = DNSStatus.ok; break;
					}
					l.callback = null;
					l.result = null;
					l.retcode = 0;
					if (i == m_maxHandle) m_maxHandle = lastmax;
					passToDNSCallback(cast(DNSLookupID)cast(int)i, cb, status, ai);
				} else lastmax = i;
			}
		}
		m_events.wait(m_event, &onDNSSignal);
	}

	private DNSLookupID getFreeHandle()
	@safe nothrow {
		assert(m_lookups.length <= int.max);
		foreach (i, ref l; m_lookups)
			if (!l.callback)
				return cast(DNSLookupID)cast(int)i;
		return cast(DNSLookupID)cast(int)m_lookups.length;
	}
}


/// getaddrinfo+thread based lookup - does not support true cancellation
final class EventDriverDNS_GAIA(Events : EventDriverEvents, Signals : EventDriverSignals) : EventDriverDNS {
	import core.sys.posix.signal : SIGEV_SIGNAL, SIGRTMIN, sigevent;

	private {
		static struct Lookup {
			gaicb ctx;
			DNSLookupCallback callback;
		}
		ChoppedVector!Lookup m_lookups;
		Signals m_signals;
		int m_dnsSignal;
		SignalListenID m_sighandle;
	}

	@safe nothrow:

	this(Events events, Signals signals)
	{
		m_signals = signals;
		m_dnsSignal = () @trusted { return SIGRTMIN; } ();
		m_sighandle = signals.listen(m_dnsSignal, &onDNSSignal);
	}

	void dispose()
	{
		m_signals.releaseRef(m_sighandle);
	}

	override DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished)
	{
		import std.string : toStringz;

		auto handle = getFreeHandle();

		sigevent evt;
		evt.sigev_notify = SIGEV_SIGNAL;
		evt.sigev_signo = m_dnsSignal;
		gaicb* res = &m_lookups[handle].ctx;
		res.ar_name = name.toStringz();
		auto ret = () @trusted { return getaddrinfo_a(GAI_NOWAIT, &res, 1, &evt); } ();

		if (ret != 0)
			return DNSLookupID.invalid;

		m_lookups[handle].callback = on_lookup_finished;

		return handle;
	}

	override void cancelLookup(DNSLookupID handle)
	{
		gai_cancel(&m_lookups[handle].ctx);
		m_lookups[handle].callback = null;
	}

	private void onDNSSignal(SignalListenID, SignalStatus status, int signal)
		@safe nothrow
	{
		assert(status == SignalStatus.ok);
		foreach (i, l; m_lookups) {
			if (!l.callback) continue;
			auto err = gai_error(&l.ctx);
			if (err == EAI_INPROGRESS) continue;
			DNSStatus status;
			switch (err) {
				default: status = DNSStatus.error; break;
				case 0: status = DNSStatus.ok; break;
			}
			auto cb = l.callback;
			auto ai = l.ctx.ar_result;
			l.callback = null;
			l.ctx.ar_result = null;
			passToDNSCallback(cast(DNSLookupID)cast(int)i, cb, status, ai);
		}
	}

	private DNSLookupID getFreeHandle()
	{
		foreach (i, ref l; m_lookups)
			if (!l.callback)
				return cast(DNSLookupID)cast(int)i;
		return cast(DNSLookupID)cast(int)m_lookups.length;
	}
}

version (linux) extern(C) {
	import core.sys.posix.signal : sigevent;

	struct gaicb {
		const(char)* ar_name;
		const(char)* ar_service;
		const(addrinfo)* ar_request;
		addrinfo* ar_result;
	}

	enum GAI_NOWAIT = 1;

	enum EAI_INPROGRESS = -100;

	int getaddrinfo_a(int mode, gaicb** list, int nitems, sigevent *sevp);
	int gai_error(gaicb *req);
	int gai_cancel(gaicb *req);
}

private void passToDNSCallback(DNSLookupID id, scope DNSLookupCallback cb, DNSStatus status, addrinfo* ai_orig)
	@trusted nothrow
{
	import std.typecons : scoped;

	static final class RefAddr : Address {
		sockaddr* sa;
		socklen_t len;
		override @property sockaddr* name() { return sa; }
		override @property const(sockaddr)* name() const { return sa; }
		override @property socklen_t nameLen() const { return len; }
	}

	try {
		typeof(scoped!RefAddr())[16] addrs_prealloc = [
			scoped!RefAddr(), scoped!RefAddr(), scoped!RefAddr(), scoped!RefAddr(),
			scoped!RefAddr(), scoped!RefAddr(), scoped!RefAddr(), scoped!RefAddr(),
			scoped!RefAddr(), scoped!RefAddr(), scoped!RefAddr(), scoped!RefAddr(),
			scoped!RefAddr(), scoped!RefAddr(), scoped!RefAddr(), scoped!RefAddr()
		];
		Address[16] addrs;
		auto ai = ai_orig;
		size_t addr_count = 0;
		while (ai !is null && addr_count < addrs.length) {
			RefAddr ua = addrs_prealloc[addr_count];
			ua.sa = ai.ai_addr;
			ua.len = ai.ai_addrlen;
			addrs[addr_count] = ua;
			addr_count++;
			ai = ai.ai_next;
		}
		cb(id, status, addrs[0 .. addr_count]);
		freeaddrinfo(ai_orig);
	} catch (Exception e) assert(false, e.msg);
}


final class PosixEventDriverEvents(Loop : PosixEventLoop) : EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
	private Loop m_loop;

	this(Loop loop) { m_loop = loop; }

	final override EventID create()
	{
		auto id = cast(EventID)eventfd(0, EFD_NONBLOCK);
		m_loop.initFD(id);
		m_loop.m_fds[id].waiters = new ConsumableQueue!EventCallback; // FIXME: avoid dynamic memory allocation
		m_loop.registerFD(id, EventMask.read);
		m_loop.startNotify!(EventType.read)(id, &onEvent);
		return id;
	}

	final override void trigger(EventID event, bool notify_all = true)
	{
		assert(event < m_loop.m_fds.length, "Invalid event ID passed to triggerEvent.");
		if (notify_all) {
			//log("emitting only for this thread (%s waiters)", m_fds[event].waiters.length);
			foreach (w; m_loop.m_fds[event].waiters.consume) {
				//log("emitting waiter %s %s", cast(void*)w.funcptr, w.ptr);
				w(event);
			}
		} else {
			if (!m_loop.m_fds[event].waiters.empty)
				m_loop.m_fds[event].waiters.consumeOne();
		}
	}

	final override void trigger(EventID event, bool notify_all = true)
	shared @trusted {
		import core.atomic : atomicStore;
		auto thisus = cast(PosixEventDriverEvents)this;
		assert(event < thisus.m_loop.m_fds.length, "Invalid event ID passed to shared triggerEvent.");
		long one = 1;
		//log("emitting for all threads");
		if (notify_all) atomicStore(thisus.m_loop.m_fds[event].triggerAll, true);
		() @trusted { .write(event, &one, one.sizeof); } ();
	}

	final override void wait(EventID event, EventCallback on_event)
	{
		assert(event < m_loop.m_fds.length, "Invalid event ID passed to waitForEvent.");
		return m_loop.m_fds[event].waiters.put(on_event);
	}

	final override void cancelWait(EventID event, EventCallback on_event)
	{
		import std.algorithm.searching : countUntil;
		import std.algorithm.mutation : remove;

		m_loop.m_fds[event].waiters.removePending(on_event);
	}

	private void onEvent(FD event)
	@trusted {
		ulong cnt;
		() @trusted { .read(event, &cnt, cnt.sizeof); } ();
		import core.atomic : cas;
		auto all = cas(&m_loop.m_fds[event].triggerAll, true, false);
		trigger(cast(EventID)event, all);
	}

	final override void addRef(EventID descriptor)
	{
		assert(m_loop.m_fds[descriptor].refCount > 0, "Adding reference to unreferenced event FD.");
		m_loop.m_fds[descriptor].refCount++;
	}

	final override bool releaseRef(EventID descriptor)
	{
		assert(m_loop.m_fds[descriptor].refCount > 0, "Releasing reference to unreferenced event FD.");
		if (--m_loop.m_fds[descriptor].refCount == 0) {
			m_loop.unregisterFD(descriptor);
			m_loop.clearFD(descriptor);
			close(descriptor);
			return false;
		}
		return true;
	}
}

final class PosixEventDriverSignals(Loop : PosixEventLoop) : EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	import core.sys.posix.signal;
	import core.sys.linux.sys.signalfd;

	private Loop m_loop;

	this(Loop loop) { m_loop = loop; }

	override SignalListenID listen(int sig, SignalCallback on_signal)
	{
		auto fd = () @trusted {
			sigset_t sset;
			sigemptyset(&sset);
			sigaddset(&sset, sig);

			if (sigprocmask(SIG_BLOCK, &sset, null) != 0)
				return SignalListenID.invalid;

			return SignalListenID(signalfd(-1, &sset, SFD_NONBLOCK));
		} ();


		m_loop.initFD(cast(FD)fd);
		m_loop.m_fds[fd].readCallback = () @trusted { return cast(IOCallback)on_signal; } (); // FIXME: avoid unsafe cast
		m_loop.registerFD(cast(FD)fd, EventMask.read);
		m_loop.setNotifyCallback!(EventType.read)(cast(FD)fd, &onSignal);

		onSignal(cast(FD)fd);

		return fd;
	}

	override void addRef(SignalListenID descriptor)
	{
		assert(m_loop.m_fds[descriptor].refCount > 0, "Adding reference to unreferenced event FD.");
		m_loop.m_fds[descriptor].refCount++;
	}
	
	override bool releaseRef(SignalListenID descriptor)
	{
		FD fd = cast(FD)descriptor;
		assert(m_loop.m_fds[fd].refCount > 0, "Releasing reference to unreferenced event FD.");
		if (--m_loop.m_fds[fd].refCount == 0) {
			m_loop.unregisterFD(fd);
			m_loop.clearFD(fd);
			close(fd);
			return false;
		}
		return true;
	}

	private void onSignal(FD fd)
	{
		SignalListenID lid = cast(SignalListenID)fd;
		auto cb = () @trusted { return cast(SignalCallback)m_loop.m_fds[fd].readCallback; } ();
		signalfd_siginfo nfo;
		do {
			auto ret = () @trusted { return read(fd, &nfo, nfo.sizeof); } ();	
			if (ret == -1 && errno == EAGAIN)
				break;
			if (ret != nfo.sizeof) {
				cb(lid, SignalStatus.error, -1);
				return;
			}
			addRef(lid);
			cb(lid, SignalStatus.ok, nfo.ssi_signo);
			releaseRef(lid);
		} while (m_loop.m_fds[fd].refCount > 0);
	}
}

final class InotifyEventDriverWatchers(Loop : PosixEventLoop) : EventDriverWatchers
{
	import core.sys.posix.fcntl, core.sys.posix.unistd, core.sys.linux.sys.inotify;
	import std.file;

	private {
		Loop m_loop;
		string[int][int] m_watches; // TODO: use a @nogc (allocator based) map
	}

	this(Loop loop) { m_loop = loop; }

	final override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback)
	{
		enum IN_NONBLOCK = 0x800; // value in core.sys.linux.sys.inotify is incorrect
		auto handle = () @trusted { return inotify_init1(IN_NONBLOCK); } ();
		if (handle == -1) return WatcherID.invalid;

		addWatch(handle, path);
		if (recursive) {
			try {
				if (path.isDir) () @trusted {
					foreach (de; path.dirEntries(SpanMode.shallow))
						if (de.isDir) addWatch(handle, de.name);
				} ();
			} catch (Exception e) {
				// TODO: decide if this should be ignored or if the error should be forwarded
			}
		}

		m_loop.initFD(FD(handle));
		m_loop.registerFD(FD(handle), EventMask.read);
		m_loop.setNotifyCallback!(EventType.read)(FD(handle), &onChanges);
		m_loop.m_fds[handle].readCallback = () @trusted { return cast(IOCallback)callback; } ();

		processEvents(WatcherID(handle));

		return WatcherID(handle);
	}

	final override void addRef(WatcherID descriptor)
	{
		assert(m_loop.m_fds[descriptor].refCount > 0, "Adding reference to unreferenced event FD.");
		m_loop.m_fds[descriptor].refCount++;
	}

	final override bool releaseRef(WatcherID descriptor)
	{
		FD fd = cast(FD)descriptor;
		assert(m_loop.m_fds[fd].refCount > 0, "Releasing reference to unreferenced event FD.");
		if (--m_loop.m_fds[fd].refCount == 0) {
			m_loop.unregisterFD(fd);
			m_loop.clearFD(fd);
			m_watches.remove(fd);
			/*errnoEnforce(*/close(fd)/* == 0)*/;
			return false;
		}

		return true;
	}

	private void onChanges(FD fd)
	{
		processEvents(cast(WatcherID)fd);
	}

	private void processEvents(WatcherID id)
	{
		import core.stdc.stdio : FILENAME_MAX;
		import core.stdc.string : strlen;

		ubyte[inotify_event.sizeof + FILENAME_MAX + 1] buf = void;
		while (true) {
			auto ret = () @trusted { return read(id, &buf[0], buf.length); } ();

			if (ret == -1 && errno == EAGAIN)
				break;
			assert(ret <= buf.length);

			auto rem = buf[0 .. ret];
			while (rem.length > 0) {
				auto ev = () @trusted { return cast(inotify_event*)rem.ptr; } ();
				FileChange ch;
				if (ev.mask & (IN_CREATE|IN_MOVED_TO))
					ch.kind = FileChangeKind.added;
				else if (ev.mask & (IN_DELETE|IN_DELETE_SELF|IN_MOVE_SELF|IN_MOVED_FROM))
					ch.kind = FileChangeKind.removed;
				else if (ev.mask & IN_MODIFY)
					ch.kind = FileChangeKind.modified;

				auto name = () @trusted { return ev.name.ptr[0 .. strlen(ev.name.ptr)]; } ();
				ch.directory = m_watches[id][ev.wd];
				ch.isDirectory = (ev.mask & IN_ISDIR) != 0;
				ch.name = name;
				addRef(id);
				auto cb = () @trusted { return cast(FileChangesCallback)m_loop.m_fds[id].readCallback; } ();
				cb(id, ch);
				if (!releaseRef(id)) break;

				rem = rem[inotify_event.sizeof + ev.len .. $];
			}
		}
	}

	private bool addWatch(int handle, string path)
	{
		import std.string : toStringz;
		enum EVENTS = IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MODIFY |
			IN_MOVE_SELF | IN_MOVED_FROM | IN_MOVED_TO;
		immutable wd = () @trusted { return inotify_add_watch(handle, path.toStringz, EVENTS); } ();
		if (wd == -1) return false;
		m_watches[cast(int)handle][wd] = path;
		return true;
	}
}

final class PosixEventDriverWatchers(Loop : PosixEventLoop) : EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	private Loop m_loop;

	this(Loop loop) { m_loop = loop; }

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

	final override bool releaseRef(WatcherID descriptor)
	{
		assert(false, "TODO!");
	}
}


package class PosixEventLoop {
@safe: nothrow:
	import core.time : Duration;

	package {
		ChoppedVector!FDSlot m_fds;
		size_t m_waiterCount = 0;
	}

	protected @property int maxFD() const { return cast(int)m_fds.length; }

	protected abstract void dispose();

	protected abstract bool doProcessEvents(Duration dur);

	/// Registers the FD for general notification reception.
	protected abstract void registerFD(FD fd, EventMask mask);
	/// Unregisters the FD for general notification reception.
	protected abstract void unregisterFD(FD fd);
	/// Updates the event mask to use for listening for notifications.
	protected abstract void updateFD(FD fd, EventMask mask);

	final protected void notify(EventType evt)(FD fd)
	{
		//assert(m_fds[fd].callback[evt] !is null, "Notifying FD which is not listening for event.");
		if (m_fds[fd].callback[evt])
			m_fds[fd].callback[evt](fd);
	}

	final protected void enumerateFDs(EventType evt)(scope FDEnumerateCallback del)
	{
		// TODO: optimize!
		foreach (i; 0 .. cast(int)m_fds.length)
			if (m_fds[i].callback[evt])
				del(cast(FD)i);
	}

	package void startNotify(EventType evt)(FD fd, FDSlotCallback callback)
	{
		//log("start notify %s %s", evt, fd);
		//assert(m_fds[fd].callback[evt] is null, "Waiting for event which is already being waited for.");
		if (callback) setNotifyCallback!evt(fd, callback);
		updateFD(fd, m_fds[fd].eventMask);
	}

	package void stopNotify(EventType evt)(FD fd)
	{
		//log("stop notify %s %s", evt, fd);
		//ssert(m_fds[fd].callback[evt] !is null, "Stopping waiting for event which is not being waited for.");
		if (m_fds[fd].callback) setNotifyCallback!evt(fd, null);
		updateFD(fd, m_fds[fd].eventMask);
	}

	package void setNotifyCallback(EventType evt)(FD fd, FDSlotCallback callback)
	{
		assert((callback !is null) != (m_fds[fd].callback[evt] !is null),
			"Overwriting notification callback.");
		// ensure that the FD doesn't get closed before the callback gets called.
		if (callback !is null) {
			m_waiterCount++;
			m_fds[fd].refCount++;
		} else {
			m_fds[fd].refCount--;
			m_waiterCount--;
		}
		m_fds[fd].callback[evt] = callback;
	}

	package void initFD(FD fd)
	{
		m_fds[fd].refCount = 1;
	}

	package void clearFD(FD fd)
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
