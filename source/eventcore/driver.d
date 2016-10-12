module eventcore.driver;
@safe: /*@nogc:*/ nothrow:

import core.time : Duration;
import std.socket : Address;


interface EventDriver {
@safe: /*@nogc:*/ nothrow:
	@property EventDriverCore core();
	@property EventDriverTimers timers();
	@property EventDriverEvents events();
	@property EventDriverSignals signals();
	@property EventDriverSockets sockets();
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
				zero will cause the function to only process pending events. The
				the default duration of `Duration.max`, if necessary, will wait
				indefinitely until an event arrives.
	*/
	ExitReason processEvents(Duration timeout = Duration.max);

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
	StreamSocketFD connectStream(scope Address peer_address, ConnectCallback on_connect);
	StreamListenSocketFD listenStream(scope Address bind_address, AcceptCallback on_accept);
	void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept);
	ConnectionState getConnectionState(StreamSocketFD sock);
	void setTCPNoDelay(StreamSocketFD socket, bool enable);
	void read(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish);
	void cancelRead(StreamSocketFD socket);
	void write(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish);
	void cancelWrite(StreamSocketFD socket);
	void waitForData(StreamSocketFD socket, IOCallback on_data_available);
	void shutdown(StreamSocketFD socket, bool shut_read = true, bool shut_write = true);

	DatagramSocketFD createDatagramSocket(scope Address bind_address, scope Address target_address);
	void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_receive_finish);
	void cancelReceive(DatagramSocketFD socket);
	void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, DatagramIOCallback on_send_finish, Address target_address = null);
	void cancelSend(DatagramSocketFD socket);

	/** Increments the reference count of the given resource.
	*/
	void addRef(SocketFD descriptor);
	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.
	*/
	void releaseRef(SocketFD descriptor);
}

interface EventDriverFiles {
@safe: /*@nogc:*/ nothrow:
	FileFD open(string path, FileOpenMode mode);
	FileFD createTemp();
	void close(FileFD file);

	ulong getSize(FileFD file);

	void write(FileFD file, ulong offset, const(ubyte)[] buffer, FileIOCallback on_write_finish);
	void read(FileFD file, ulong offset, ubyte[] buffer, FileIOCallback on_read_finish);
	void cancelWrite(FileFD file);
	void cancelRead(FileFD file);

	/** Increments the reference count of the given resource.
	*/
	void addRef(FileFD descriptor);
	
	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.
	*/
	void releaseRef(FileFD descriptor);
}

interface EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
	EventID create();
	void trigger(EventID event, bool notify_all = true);
	void trigger(EventID event, bool notify_all = true) shared;
	void wait(EventID event, EventCallback on_event);
	void cancelWait(EventID event, EventCallback on_event);

	/** Increments the reference count of the given resource.
	*/
	void addRef(EventID descriptor);
	
	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.
	*/
	void releaseRef(EventID descriptor);
}

interface EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	void wait(int sig, SignalCallback on_signal);
	void cancelWait(int sig);
}

interface EventDriverTimers {
@safe: /*@nogc:*/ nothrow:
	TimerID create();
	void set(TimerID timer, Duration timeout, Duration repeat = Duration.zero);
	void stop(TimerID timer);
	bool isPending(TimerID timer);
	bool isPeriodic(TimerID timer);
	void wait(TimerID timer, TimerCallback callback);
	void cancelWait(TimerID timer, TimerCallback callback);

	/** Increments the reference count of the given resource.
	*/
	void addRef(TimerID descriptor);
	
	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.
	*/
	void releaseRef(TimerID descriptor);
}

interface EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	WatcherID watchDirectory(string path, bool recursive);
	void wait(WatcherID watcher, FileChangesCallback callback);
	void cancelWait(WatcherID watcher);

	/** Increments the reference count of the given resource.
	*/
	void addRef(WatcherID descriptor);
	
	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.
	*/
	void releaseRef(WatcherID descriptor);
}


alias ConnectCallback = void delegate(StreamSocketFD, ConnectStatus);
alias AcceptCallback = void delegate(StreamListenSocketFD, StreamSocketFD);
alias IOCallback = void delegate(StreamSocketFD, IOStatus, size_t);
alias DatagramIOCallback = void delegate(DatagramSocketFD, IOStatus, size_t, scope Address);
alias FileIOCallback = void delegate(FileFD, IOStatus, size_t);
alias EventCallback = void delegate(EventID);
alias SignalCallback = void delegate(int);
alias TimerCallback = void delegate(TimerID);
alias FileChangesCallback = void delegate(WatcherID, in FileChange[] changes);
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


/** Describes a single change in a watched directory.
*/
struct FileChange {
	/// The type of change
	FileChangeKind type;

	/// Path of the file/directory that was changed
	string path;
}

struct Handle(string NAME, T, T invalid_value = T.init) {
	static if (is(T : Handle!(N, V, M), string N, V, int M)) alias BaseType = T.BaseType;
	else alias BaseType = T;

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

alias FD = Handle!("FD", int, -1);
alias SocketFD = Handle!("Socket", FD);
alias StreamSocketFD = Handle!("Stream", SocketFD);
alias StreamListenSocketFD = Handle!("StreamListen", SocketFD);
alias DatagramSocketFD = Handle!("Datagram", SocketFD);
alias FileFD = Handle!("File", FD);
alias EventID = Handle!("Event", FD);
alias TimerID = Handle!("Timer", int);
alias WatcherID = Handle!("Watcher", int);
alias EventWaitID = Handle!("EventWait", int);
