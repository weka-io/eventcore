module eventcore.driver;
@safe: /*@nogc:*/ nothrow:

import core.time : Duration;
import std.socket : Address;


interface EventDriver {
@safe: /*@nogc:*/ nothrow:
	@property EventDriverCore core();
	@property EventDriverTimers timers();
	@property EventDriverEvents events();
	@property shared(EventDriverEvents) events() shared;
	@property EventDriverSignals signals();
	@property EventDriverSockets sockets();
	@property EventDriverDNS dns();
	@property EventDriverFiles files();
	@property EventDriverWatchers watchers();

	/// Releases all resources associated with the driver
	void dispose();
}

interface EventDriverCore {
@safe: /*@nogc:*/ nothrow:
	/** The number of pending callbacks.

		When this number drops to zero, the event loop can safely be quit. It is
		guaranteed that no callbacks will be made anymore, unless new callbacks
		get registered.
	*/
	size_t waiterCount();

	/** Runs the event loop to process a chunk of events.

		This method optionally waits for an event to arrive if none are present
		in the event queue. The function will return after either the specified
		timeout has elapsed, or once the event queue has been fully emptied.

		Params:
			timeout = Maximum amount of time to wait for an event. A duration of
				zero will cause the function to only process pending events. A
				duration of `Duration.max`, if necessary, will wait indefinitely
				until an event arrives.
	*/
	ExitReason processEvents(Duration timeout);

	/** Causes `processEvents` to return with `ExitReason.exited` as soon as
		possible.

		A call to `processEvents` that is currently in progress will be notfied
		so that it returns immediately. If no call is in progress, the next call
		to `processEvents` will immediately return with `ExitReason.exited`.
	*/
	void exit();

	/** Resets the exit flag.

		`processEvents` will automatically reset the exit flag before it returns
		with `ExitReason.exited`. However, if `exit` is called outside of
		`processEvents`, the next call to `processEvents` will return with
		`ExitCode.exited` immediately. This function can be used to avoid this.
	*/
	void clearExitFlag();

	/// Low-level user data access. Use `getUserData` instead.
	protected void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
	/// ditto
	protected void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T, FD)(FD descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) { emplace(cast(T*)ptr); }
		static void destr(void* ptr) { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}
}

interface EventDriverSockets {
@safe: /*@nogc:*/ nothrow:
	StreamSocketFD connectStream(scope Address peer_address, scope Address bind_address, ConnectCallback on_connect);
	StreamListenSocketFD listenStream(scope Address bind_address, AcceptCallback on_accept);
	void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept);
	ConnectionState getConnectionState(StreamSocketFD sock);
	bool getLocalAddress(StreamSocketFD sock, scope RefAddress dst);
	void setTCPNoDelay(StreamSocketFD socket, bool enable);
	void setKeepAlive(StreamSocketFD socket, bool enable);
	void read(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish);
	void cancelRead(StreamSocketFD socket);
	void write(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish);
	void cancelWrite(StreamSocketFD socket);
	void waitForData(StreamSocketFD socket, IOCallback on_data_available);
	void shutdown(StreamSocketFD socket, bool shut_read, bool shut_write);

	DatagramSocketFD createDatagramSocket(scope Address bind_address, scope Address target_address);
	bool setBroadcast(DatagramSocketFD socket, bool enable);
	void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_receive_finish);
	void cancelReceive(DatagramSocketFD socket);
	void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, scope Address target_address, DatagramIOCallback on_send_finish);
	void cancelSend(DatagramSocketFD socket);

	/** Increments the reference count of the given resource.
	*/
	void addRef(SocketFD descriptor);
	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(SocketFD descriptor);
}

interface EventDriverDNS {
@safe: /*@nogc:*/ nothrow:
	DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished);
	void cancelLookup(DNSLookupID handle);
}

interface EventDriverFiles {
@safe: /*@nogc:*/ nothrow:
	FileFD open(string path, FileOpenMode mode);
	FileFD adopt(int system_file_handle);
	void close(FileFD file);

	ulong getSize(FileFD file);

	void write(FileFD file, ulong offset, const(ubyte)[] buffer, IOMode mode, FileIOCallback on_write_finish);
	void read(FileFD file, ulong offset, ubyte[] buffer, IOMode mode, FileIOCallback on_read_finish);
	void cancelWrite(FileFD file);
	void cancelRead(FileFD file);

	/** Increments the reference count of the given resource.
	*/
	void addRef(FileFD descriptor);
	
	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(FileFD descriptor);
}

interface EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
	EventID create();
	void trigger(EventID event, bool notify_all);
	void trigger(EventID event, bool notify_all) shared;
	void wait(EventID event, EventCallback on_event);
	void cancelWait(EventID event, EventCallback on_event);

	/** Increments the reference count of the given resource.
	*/
	void addRef(EventID descriptor);
	
	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(EventID descriptor);
}

interface EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	SignalListenID listen(int sig, SignalCallback on_signal);

	/** Increments the reference count of the given resource.
	*/
	void addRef(SignalListenID descriptor);
	
	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(SignalListenID descriptor);
}

interface EventDriverTimers {
@safe: /*@nogc:*/ nothrow:
	TimerID create();
	void set(TimerID timer, Duration timeout, Duration repeat);
	void stop(TimerID timer);
	bool isPending(TimerID timer);
	bool isPeriodic(TimerID timer);
	void wait(TimerID timer, TimerCallback callback);
	void cancelWait(TimerID timer);

	/** Increments the reference count of the given resource.
	*/
	void addRef(TimerID descriptor);
	
	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(TimerID descriptor);
}

interface EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback);

	/** Increments the reference count of the given resource.
	*/
	void addRef(WatcherID descriptor);
	
	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.
	*/
	bool releaseRef(WatcherID descriptor);
}

final class RefAddress : Address {
	version (Posix) import 	core.sys.posix.sys.socket : sockaddr, socklen_t;
	version (Windows) import core.sys.windows.winsock2 : sockaddr, socklen_t;

	private {
		sockaddr* m_addr;
		socklen_t m_addrLen;
	}

	this() @safe nothrow {}
	this(sockaddr* addr, socklen_t addr_len) @safe nothrow { set(addr, addr_len); }

	override @property sockaddr* name() { return m_addr; }
	override @property const(sockaddr)* name() const { return m_addr; }
	override @property socklen_t nameLen() const { return m_addrLen; }

	void set(sockaddr* addr, socklen_t addr_len) @safe nothrow { m_addr = addr; m_addrLen = addr_len; }

	void cap(socklen_t new_len)
	@safe nothrow {
		assert(new_len <= m_addrLen, "Cannot grow size of a RefAddress.");
		m_addrLen = new_len;
	}
}


alias ConnectCallback = void delegate(StreamSocketFD, ConnectStatus);
alias AcceptCallback = void delegate(StreamListenSocketFD, StreamSocketFD, scope RefAddress remote_address);
alias IOCallback = void delegate(StreamSocketFD, IOStatus, size_t);
alias DatagramIOCallback = void delegate(DatagramSocketFD, IOStatus, size_t, scope RefAddress);
alias DNSLookupCallback = void delegate(DNSLookupID, DNSStatus, scope RefAddress[]);
alias FileIOCallback = void delegate(FileFD, IOStatus, size_t);
alias EventCallback = void delegate(EventID);
alias SignalCallback = void delegate(SignalListenID, SignalStatus, int);
alias TimerCallback = void delegate(TimerID);
alias FileChangesCallback = void delegate(WatcherID, in ref FileChange change);
@system alias DataInitializer = void function(void*);

enum ExitReason {
	timeout,
	idle,
	outOfWaiters,
	exited
}

enum ConnectStatus {
	connected,
	refused,
	timeout,
	bindFailure,
	unknownError
}

enum ConnectionState {
	initialized,
	connecting,
	connected,
	passiveClose,
	activeClose,
	closed
}

/**
	Specifies how a file is manipulated on disk.
*/
enum FileOpenMode {
	/// The file is opened read-only.
	read,
	/// The file is opened for read-write random access.
	readWrite,
	/// The file is truncated if it exists or created otherwise and then opened for read-write access.
	createTrunc,
	/// The file is opened for appending data to it and created if it does not exist.
	append
}

enum IOMode {
	immediate, /// Process only as much as possible without waiting
	once,      /// Process as much as possible with a single call
	all        /// Process the full buffer
}

enum IOStatus {
	ok,           /// The data has been transferred normally
	disconnected, /// The connection was closed before all data could be transterred
	error,        /// An error occured while transferring the data
	wouldBlock    /// Returned for `IOMode.immediate` when no data is readily readable/writable
}

enum DNSStatus {
	ok,
	error
}

/** Specifies the kind of change in a watched directory.
*/
enum FileChangeKind {
	/// A file or directory was added
	added,
	/// A file or directory was deleted
	removed,
	/// A file or directory was modified
	modified
}

enum SignalStatus {
	ok,
	error
}


/** Describes a single change in a watched directory.
*/
struct FileChange {
	/// The type of change
	FileChangeKind kind;

	/// Directory containing the changed file
	string directory;

	/// Determines if the changed entity is a file or a directory.
	bool isDirectory;

	/// Name of the changed file
	const(char)[] name;
}

struct Handle(string NAME, T, T invalid_value = T.init) {
	static if (is(T : Handle!(N, V, M), string N, V, int M)) alias BaseType = T.BaseType;
	else alias BaseType = T;

	alias name = NAME;

	enum invalid = Handle.init;

	T value = invalid_value;

	this(BaseType value) { this.value = T(value); }

	U opCast(U : Handle!(V, M), V, int M)() {
		// TODO: verify that U derives from typeof(this)!
		return U(value);
	}

	U opCast(U : BaseType)()
	{
		return cast(U)value;
	}

	alias value this;
}

alias FD = Handle!("fd", int, -1);
alias SocketFD = Handle!("socket", FD);
alias StreamSocketFD = Handle!("streamSocket", SocketFD);
alias StreamListenSocketFD = Handle!("streamListen", SocketFD);
alias DatagramSocketFD = Handle!("datagramSocket", SocketFD);
alias FileFD = Handle!("file", FD);
alias EventID = Handle!("event", FD);
alias TimerID = Handle!("timer", int);
alias WatcherID = Handle!("watcher", int);
alias EventWaitID = Handle!("eventWait", int);
alias SignalListenID = Handle!("signal", int);
alias DNSLookupID = Handle!("dns", int);
