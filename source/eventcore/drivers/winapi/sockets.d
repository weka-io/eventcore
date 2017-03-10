module eventcore.drivers.winapi.sockets;

version (Windows):

import eventcore.driver;
import eventcore.internal.win32;
import std.socket : Address;


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

	alias listenStream = EventDriverSockets.listenStream;
	override StreamListenSocketFD listenStream(scope Address bind_address, StreamListenOptions options, AcceptCallback on_accept)
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

	override bool getLocalAddress(SocketFD sock, scope RefAddress dst)
	{
		assert(false, "TODO!");
	}

	override bool getRemoteAddress(SocketFD sock, scope RefAddress dst)
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
