module eventcore.driver;
@safe: /*@nogc:*/ nothrow:

import core.time : Duration;
import std.socket : Address;


interface EventDriver {
@safe: /*@nogc:*/ nothrow:
	//
	// General functionality
	//

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

	//
	// TCP
	//
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

	//
	// Files
	//
	//FileFD openFile(string path, FileOpenMode mode);
	//FileFD createTempFile();

	//
	// Manual events
	//
	EventID createEvent();
	void triggerEvent(EventID event, bool notify_all = true);
	void triggerEvent(EventID event, bool notify_all = true) shared;
	void waitForEvent(EventID event, EventCallback on_event);
	void cancelWaitForEvent(EventID event, EventCallback on_event);

	//
	// Timers
	//
	TimerID createTimer();
	void setTimer(TimerID timer, Duration timeout, Duration repeat = Duration.zero);
	void stopTimer(TimerID timer);
	bool isTimerPending(TimerID timer);
	bool isTimerPeriodic(TimerID timer);
	void waitTimer(TimerID timer, TimerCallback callback);
	void cancelTimerWait(TimerID timer, TimerCallback callback);

	//
	// Resource ownership
	//

	/**
		Increments the reference count of the given resource.
	*/
	void addRef(SocketFD descriptor);
	/// ditto
	void addRef(FileFD descriptor);
	/// ditto
	void addRef(TimerID descriptor);
	/// ditto
	void addRef(EventID descriptor);

	/**
		Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.
	*/
	void releaseRef(SocketFD descriptor);
	/// ditto
	void releaseRef(FileFD descriptor);
	/// ditto
	void releaseRef(TimerID descriptor);
	/// ditto
	void releaseRef(EventID descriptor);


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


alias ConnectCallback = void delegate(StreamSocketFD, ConnectStatus);
alias AcceptCallback = void delegate(StreamListenSocketFD, StreamSocketFD);
alias IOCallback = void delegate(StreamSocketFD, IOStatus, size_t);
alias EventCallback = void delegate(EventID);
alias TimerCallback = void delegate(TimerID);
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

struct Handle(T, T invalid_value = T.init, int MAGIC = __LINE__) {
	static if (is(T : Handle!(V, M), V, int M)) alias BaseType = T.BaseType;
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

alias FD = Handle!(int, -1);
alias SocketFD = Handle!FD;
alias StreamSocketFD = Handle!SocketFD;
alias StreamListenSocketFD = Handle!SocketFD;
alias FileFD = Handle!FD;
alias EventID = Handle!FD;
alias TimerID = Handle!int;
alias EventWaitID = Handle!int;
