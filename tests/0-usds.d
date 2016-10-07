/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

version (Posix) {} else {
	void main()
	{
		import std.stdio;
		writeln("Skipping Unix domain sockets test on this platform.");
	}
}

version (Posix):

import eventcore.core;
import eventcore.socket;
import std.file : exists, remove;
import std.socket : UnixAddress;

ubyte[256] s_rbuf;
bool s_done;

enum addr1 = "/tmp/eventcore-test.uds";
enum addr2 = "/tmp/eventcore-test-2.uds";
enum addr3 = "/tmp/eventcore-test-3.uds";

void testDgram()
@safe nothrow {
	static ubyte[] pack1 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
	static ubyte[] pack2 = [4, 3, 2, 1, 0];

	if (exists(addr1)) try remove(addr1); catch (Exception e) {}
	if (exists(addr2)) try remove(addr2); catch (Exception e) {}
	if (exists(addr3)) try remove(addr3); catch (Exception e) {}

	scope (failure) assert(false);

	auto baddr 	= new UnixAddress(addr1);
	auto s_baseSocket = createDatagramSocket(baddr);
	auto s_freeSocket = createDatagramSocket(new UnixAddress(addr2));
	auto s_connectedSocket = createDatagramSocket(new UnixAddress(addr3), baddr);
	log("drec");
	s_baseSocket.receive!((status, bytes, addr) {
		assert(status == IOStatus.wouldBlock);
	})(s_rbuf, IOMode.immediate);
	log("drec2");
	s_baseSocket.receive!((status, bts, address) {
		assert(status == IOStatus.ok);
		assert(bts == pack1.length);
		assert(s_rbuf[0 .. pack1.length] == pack1);

	log("dsend2");
		s_freeSocket.send!((status, bytes) {
			assert(status == IOStatus.ok);
			assert(bytes == pack2.length);
		})(pack2, IOMode.once, baddr);

	log("drec3");
		s_baseSocket.receive!((status, bts, scope addr) {
	log("drec3done");
			assert(status == IOStatus.ok);
			assert(bts == pack2.length);
			assert(s_rbuf[0 .. pack2.length] == pack2);

			destroy(s_baseSocket);
			destroy(s_freeSocket);
			destroy(s_connectedSocket);
			s_done = true;

			// FIXME: this shouldn't ne necessary:
			eventDriver.core.exit();
		})(s_rbuf, IOMode.immediate);
	})(s_rbuf, IOMode.once);
	log("dsend");
	s_connectedSocket.send!((status, bytes) {
	log("dsenddone");
		assert(status == IOStatus.ok);
		assert(bytes == 10);
	})(pack1, IOMode.immediate);


	ExitReason er;
	do er = eventDriver.core.processEvents();
	while (er == ExitReason.idle);
	//assert(er == ExitReason.outOfWaiters); // FIXME: see above
	assert(s_done);
	s_done = false;
}

void testStream()
{
	static ubyte[] pack1 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
	static ubyte[] pack2 = [4, 3, 2, 1, 0];

	if (exists(addr1)) try remove(addr1); catch (Exception e) {}

	auto baddr 	= new UnixAddress(addr1);
	auto server = listenStream(baddr);
	StreamSocket client;

				log("connect");
	connectStream!((sock, status) {
		client = sock;
		assert(status == ConnectStatus.connected);
				log("write1");
		client.write!((wstatus, bytes) {
				log("written1");
			{ import std.stdio; scope (failure) assert(false); writefln("%s %s", wstatus, bytes); }
			assert(wstatus == IOStatus.ok);
			assert(bytes == 10);
		})(pack1, IOMode.all);
	})(baddr);

				log("listen");
	server.waitForConnections!((ref incoming) {
				log("read1");
		incoming.read!((status, bts) {
			assert(status == IOStatus.ok);
			assert(bts == pack1.length);
			assert(s_rbuf[0 .. pack1.length] == pack1);

				log("write2");
			client.write!((status, bytes) {
				assert(status == IOStatus.ok);
				assert(bytes == pack2.length);
			})(pack2, IOMode.once);

				log("read2");
			incoming.read!((status, bts) {
				assert(status == IOStatus.ok);
				assert(bts == pack2.length);
				assert(s_rbuf[0 .. pack2.length] == pack2);

				destroy(incoming);
				destroy(server);
				destroy(client);
				s_done = true;

				// FIXME: this shouldn't ne necessary:
				eventDriver.core.exit();
			})(s_rbuf, IOMode.once);
		})(s_rbuf, IOMode.once);
	});

	ExitReason er;
	do er = eventDriver.core.processEvents();
	while (er == ExitReason.idle);
	//assert(er == ExitReason.outOfWaiters); // FIXME: see above
	assert(s_done);
	s_done = false;
}

void main()
{
	testStream();
	testDgram();
}

void log(ARGS...)(string fmt, ARGS args)
{
	import std.stdio;
	try writefln(fmt, args);
	catch (Exception e) {}
}
