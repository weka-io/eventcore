module eventcore.socket;

import eventcore.core : eventDriver;
import eventcore.driver;
import std.exception : enforce;
import std.socket : Address;


StreamSocket connectStream(scope Address peer_address, ConnectCallback on_connect)
@safe {
	auto fd = eventDriver.sockets.connectStream(peer_address, on_connect);
	enforce(fd != DatagramSocketFD.init, "Failed to create socket.");
	return StreamSocket(fd);
}

StreamListenSocket listenStream(scope Address bind_address, AcceptCallback on_accept)
@safe {
	auto fd = eventDriver.sockets.listenStream(bind_address, on_accept);
	enforce(fd != DatagramSocketFD.init, "Failed to create socket.");
	return StreamListenSocket(fd);
}

DatagramSocket createDatagramSocket(scope Address bind_address, scope Address target_address = null)
@safe {
	auto fd = eventDriver.sockets.createDatagramSocket(bind_address, target_address);
	enforce(fd != DatagramSocketFD.init, "Failed to create socket.");
	return DatagramSocket(fd);
}

/*alias ConnectCallback = void delegate(ConnectStatus);
alias AcceptCallback = void delegate(StreamSocket);
alias IOCallback = void delegate(IOStatus, size_t);*/

struct StreamSocket {
	@safe: nothrow:

	private StreamSocketFD m_fd;

	private this(StreamSocketFD fd)
	{
		m_fd = fd;
	}

	this(this) { if (m_fd != StreamSocketFD.init) eventDriver.sockets.addRef(m_fd); }
	~this() { if (m_fd != StreamSocketFD.init) eventDriver.sockets.releaseRef(m_fd); }

	@property ConnectionState state() { return eventDriver.sockets.getConnectionState(m_fd); }
	@property void tcpNoDelay(bool enable) { eventDriver.sockets.setTCPNoDelay(m_fd, enable); }

	void read(ubyte[] buffer, IOMode mode, IOCallback on_read_finish) { eventDriver.sockets.read(m_fd, buffer, mode, on_read_finish); }
	void cancelRead() { eventDriver.sockets.cancelRead(m_fd); }
	void waitForData(IOCallback on_data_available) { eventDriver.sockets.waitForData(m_fd, on_data_available); }
	void write(const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish) { eventDriver.sockets.write(m_fd, buffer, mode, on_write_finish); }
	void cancelWrite() { eventDriver.sockets.cancelWrite(m_fd); }
	void shutdown(bool shut_read = true, bool shut_write = true) { eventDriver.sockets.shutdown(m_fd, shut_read, shut_write); }
}

struct StreamListenSocket {
	@safe: nothrow:

	private StreamListenSocketFD m_fd;

	private this(StreamListenSocketFD fd)
	{
		m_fd = fd;
	}

	this(this) { if (m_fd != StreamListenSocketFD.init) eventDriver.sockets.addRef(m_fd); }
	~this() { if (m_fd != StreamListenSocketFD.init) eventDriver.sockets.releaseRef(m_fd); }

	void waitForConnections(AcceptCallback on_accept)
	{
		eventDriver.sockets.waitForConnections(m_fd, on_accept);
	}
}

struct DatagramSocket {
	@safe: nothrow:

	private DatagramSocketFD m_fd;

	private this(DatagramSocketFD fd)
	{
		m_fd = fd;
	}

	this(this) { if (m_fd != DatagramSocketFD.init) eventDriver.sockets.addRef(m_fd); }
	~this() { if (m_fd != DatagramSocketFD.init) eventDriver.sockets.releaseRef(m_fd); }
}

void receive(alias callback)(ref DatagramSocket socket, ubyte[] buffer, IOMode mode) {
	void cb(DatagramSocketFD fd, IOStatus status, size_t bytes_written, scope Address address) @safe nothrow {
		callback(status, bytes_written, address);
	}
	eventDriver.sockets.receive(socket.m_fd, buffer, mode, &cb);
}
void cancelReceive(ref DatagramSocket socket) { eventDriver.sockets.cancelReceive(socket.m_fd); }
void send(alias callback)(ref DatagramSocket socket, const(ubyte)[] buffer, IOMode mode, Address target_address = null) {
	void cb(DatagramSocketFD fd, IOStatus status, size_t bytes_written, scope Address) @safe nothrow {
		callback(status, bytes_written);
	}
	eventDriver.sockets.send(socket.m_fd, buffer, mode, &cb, target_address);
}
void cancelSend(ref DatagramSocket socket) { eventDriver.sockets.cancelSend(socket.m_fd); }
