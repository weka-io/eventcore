module eventcore.internal.corefoundation;

version (Darwin):

extern(C):

static if (!is(typeof(CFRelease))) {
	alias CFTypeRef = const(void)*;
	alias CFTypeRef CFAllocatorRef;
	extern const CFAllocatorRef kCFAllocatorDefault;
	CFTypeRef CFRetain(CFTypeRef cf);
	void CFRelease(CFTypeRef cf);
}

static if (!is(typeof(CFRunLoop))) {
	alias CFRunLoopMode = CFStringRef;
	struct __CFRunLoop;
	alias CFRunLoopRef = __CFRunLoop*;
	struct __CFRunLoopSource;
	alias CFRunLoopSourceRef = __CFRunLoopSource*;

	alias CFTimeInterval = double;
	alias Boolean = bool;

	extern const CFStringRef kCFRunLoopDefaultMode;
	extern const CFStringRef kCFRunLoopCommonModes;

	void CFRunLoopAddSource(CFRunLoopRef rl, CFRunLoopSourceRef source, CFRunLoopMode mode);
	CFRunLoopRunResult CFRunLoopRunInMode(CFRunLoopMode mode, CFTimeInterval seconds, Boolean returnAfterSourceHandled);
}

static if (!is(CFFileDescriptor)) {
	alias FSEventStreamRef = x;
	FSEventStreamRef FSEventStreamCreate(CFAllocatorRef allocator, FSEventStreamCallback callback, FSEventStreamContext *context, CFArrayRef pathsToWatch, FSEventStreamEventId sinceWhen, CFTimeInterval latency, FSEventStreamCreateFlags flags);
}
