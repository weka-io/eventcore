/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import eventcore.socket;
import std.socket : InternetAddress;
import core.time : Duration;

ubyte[256] s_rbuf;
bool s_done;

void main()
{
	static ubyte[] pack1 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
	static ubyte[] pack2 = [4, 3, 2, 1, 0];

	auto baddr 	= new InternetAddress(0x7F000001, 40001);
	auto server = listenStream(baddr);
	StreamSocket client;
	StreamSocket incoming;

	server.waitForConnections!((incoming_, addr) {
		incoming = incoming_; // work around ref counting issue
		incoming.read!((status, bts) {
			assert(status == IOStatus.ok);
			assert(bts == pack1.length);
			assert(s_rbuf[0 .. pack1.length] == pack1);

			client.write!((status, bytes) {
				assert(status == IOStatus.ok);
				assert(bytes == pack2.length);
			})(pack2, IOMode.once);

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

	connectStream!((sock, status) {
		client = sock;
		assert(status == ConnectStatus.connected);
		client.write!((wstatus, bytes) {
			assert(wstatus == IOStatus.ok);
			assert(bytes == 10);
		})(pack1, IOMode.all);
	})(baddr);

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	//assert(er == ExitReason.outOfWaiters); // FIXME: see above
	assert(s_done);
	s_done = false;
}
