/**
	`CFRunLoop` based event loop for macOS UI compatible operation.
*/
module eventcore.drivers.posix.cfrunloop;
@safe: /*@nogc:*/ nothrow:

version (EventcoreCFRunLoopDriver):

import eventcore.drivers.posix.kqueue;
import eventcore.internal.corefoundation;
import eventcore.internal.utils;
import core.time;


alias CFRunLoopEventDriver = PosixEventDriver!CFRunLoopEventLoop;

final class CFRunLoopEventLoop : KqueueEventLoopBase {
@safe nothrow:
	private {
		CFFileDescriptorRef m_kqueueDescriptor;
		CFRunLoopSourceRef m_kqueueSource;
	}

	this()
	@trusted @nogc {
		super();

		CFFileDescriptorContext ctx;
		ctx.info = cast(void*)this;

		m_kqueueDescriptor = CFFileDescriptorCreate(kCFAllocatorDefault,
			m_queue, false, &processKqueue, &ctx);

		m_kqueueSource = CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, m_kqueueDescriptor, 0);
		CFRunLoopAddSource(CFRunLoopGetCurrent(), m_kqueueSource, kCFRunLoopDefaultMode);
	}

	override bool doProcessEvents(Duration timeout)
	@trusted {
		import std.algorithm.comparison : min;

		CFFileDescriptorEnableCallBacks(m_kqueueDescriptor, CFOptionFlags.kCFFileDescriptorReadCallBack);

		// submit changes and process pending events
		auto kres = doProcessEventsBase(0.seconds);
		if (kres) timeout = 0.seconds;

		// NOTE: the timeout per CFRunLoopRunInMode call is limited to one
		//       second to work around the issue that the kqueue CFFileDescriptor
		//       sometimes does not fire. There seems to be some kind of race-
		//       condition, between the edge-triggered kqueue events and
		//       CFFileDescriptorEnableCallBacks/CFRunLoopRunInMode.
		//
		//       Even changing the order of calls in processKqueue to first
		//       re-enable the callbacks and *then* process the already pending
		//       events does not help (and is also eplicitly discouraged in
		//       Apple's documentation).
		while (timeout > 0.seconds) {
			auto tol = min(timeout, 5.seconds);
			timeout -= tol;
			CFTimeInterval to = 1e-7 * tol.total!"hnsecs";
			auto res = CFRunLoopRunInMode(kCFRunLoopDefaultMode, to, true);
			if (res != CFRunLoopRunResult.kCFRunLoopRunTimedOut) {
				return kres || res == CFRunLoopRunResult.kCFRunLoopRunHandledSource;
			}

			CFFileDescriptorEnableCallBacks(m_kqueueDescriptor, CFOptionFlags.kCFFileDescriptorReadCallBack);
			kres = doProcessEventsBase(0.seconds);
			if (kres) break;
		}

		return kres;
	}

	override void dispose()
	{
		() @trusted {
			CFRelease(m_kqueueSource);
			CFRelease(m_kqueueDescriptor);
		} ();
		super.dispose();
	}

	private static extern(C) void processKqueue(CFFileDescriptorRef fdref,
		CFOptionFlags callBackTypes, void* info)
	{
		auto this_ = () @trusted { return cast(CFRunLoopEventLoop)info; } ();
		this_.doProcessEventsBase(0.seconds);
	}
}
