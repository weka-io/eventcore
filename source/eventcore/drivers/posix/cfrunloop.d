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

		CFFileDescriptorEnableCallBacks(m_kqueueDescriptor, CFOptionFlags.kCFFileDescriptorReadCallBack);
		m_kqueueSource = CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, m_kqueueDescriptor, 0);
		CFRunLoopAddSource(CFRunLoopGetCurrent(), m_kqueueSource, kCFRunLoopDefaultMode);
	}

	override bool doProcessEvents(Duration timeout)
	@trusted {
		// submit changes and process pending events
		auto kres = doProcessEventsBase(0.seconds);

		CFTimeInterval to = kres ? 0.0 : 1e-7 * timeout.total!"hnsecs";
		auto res = CFRunLoopRunInMode(kCFRunLoopDefaultMode, to, true);
		return kres || res == CFRunLoopRunResult.kCFRunLoopRunHandledSource;
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
		auto res = this_.doProcessEventsBase(0.seconds);
		() @trusted { CFFileDescriptorEnableCallBacks(this_.m_kqueueDescriptor, CFOptionFlags.kCFFileDescriptorReadCallBack); } ();
	}
}
