module eventcore.driver;
@safe: /*@nogc:*/ nothrow:

import core.time : Duration;
import std.socket : Address;


interface EventDriver {
@safe: /*@nogc:*/ nothrow:
	@property EventDriverCore core();
	@property EventDriverFiles files();
	@property EventDriverSockets sockets();
	@property EventDriverTimers udp();
	@property EventDriverEvents events();
	@property EventDriverSignals signals();
	@property EventDriverWatchers watchers();
}

interface EventDriverCore {
@safe: /*@nogc:*/ nothrow:
	/// Releases all resources associated with the driver
	void dispose();

	/**
		The number of pending callbacks.

		When this number drops to zero, the event loop can safely be quit. It is
		guaranteed that no callbacks will be made anymore, unless new callbacks
		get registered.
	*/
	size_t waiterCount();

	/**
		Runs the event loop to process a chunk of events.

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

	/**
		Causes `processEvents` to return with `ExitReason.exited` as soon as
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
	/**
		Increments the reference count of the given resource.
	*/
	void addRef(SocketFD descriptor);
	/**
		Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.
	*/
	void releaseRef(SocketFD descriptor);

	StreamSocketFD connectStream(scope Address peer_address, ConnectCallback on_connect);
	StreamListenSocketFD listenStream(scope Address bind_address, AcceptCallback on_accept);
	void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept);
	ConnectionState getConnectionState(StreamSocketFD sock);
	void setTCPNoDelay(StreamSocketFD socket, bool enable);
	void readSocket(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish);
	void writeSocket(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish);
	void waitSocketData(StreamSocketFD socket, IOCallback on_data_available);
	void shutdownSocket(StreamSocketFD socket, bool shut_read = true, bool shut_write = true);
	void cancelRead(StreamSocketFD socket);
	void cancelWrite(StreamSocketFD socket);
}

interface EventDriverFiles {
@safe: /*@nogc:*/ nothrow:
	/**
		Increments the reference count of the given resource.
	*/
	void addRef(FileFD descriptor);
	/**
		Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.
	*/
	void releaseRef(FileFD descriptor);

	FileFD openFile(string path, FileOpenMode mode);
	FileFD createTempFile();
	void write(FileFD file, ulong offset, ubyte[] buffer, IOCallback on_write_finish);
	void read(FileFD file, ulong offset, ubyte[] buffer, IOCallback on_read_finish);
	void cancelWrite(FileFD file);
	void cancelRead(FileFD file);
}

interface EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
	/**
		Increments the reference count of the given resource.
	*/
	void addRef(EventID descriptor);
	/**
		Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.
	*/
	void releaseRef(EventID descriptor);

	EventID createEvent();
	void triggerEvent(EventID event, bool notify_all = true);
	void triggerEvent(EventID event, bool notify_all = true) shared;
	void waitForEvent(EventID event, EventCallback on_event);
	void cancelWaitForEvent(EventID event, EventCallback on_event);
}

interface EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	void waitForSignal(int sig, SignalCallback on_signal);
	void cancelWaitForSignal(int sig);
}

interface EventDriverTimers {
@safe: /*@nogc:*/ nothrow:
	/**
		Increments the reference count of the given resource.
	*/
	void addRef(TimerID descriptor);
	/**
		Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.
	*/
	void releaseRef(TimerID descriptor);

	TimerID createTimer();
	void setTimer(TimerID timer, Duration timeout, Duration repeat = Duration.zero);
	void stopTimer(TimerID timer);
	bool isTimerPending(TimerID timer);
	bool isTimerPeriodic(TimerID timer);
	void waitTimer(TimerID timer, TimerCallback callback);
	void cancelTimerWait(TimerID timer, TimerCallback callback);
}

interface EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	WatcherID watchDirectory(string path, bool recursive);
	void waitForChanges(WatcherID watcher, FileChangesCallback callback);
	void cancelWaitForChanges(WatcherID watcher);
}


alias ConnectCallback = void delegate(StreamSocketFD, ConnectStatus);
alias AcceptCallback = void delegate(StreamListenSocketFD, StreamSocketFD);
alias IOCallback = void delegate(StreamSocketFD, IOStatus, size_t);
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
alias FileFD = Handle!("File", FD);
alias EventID = Handle!("Event", FD);
alias TimerID = Handle!("Timer", int);
alias WatcherID = Handle!("Watcher", int);
alias EventWaitID = Handle!("EventWait", int);
