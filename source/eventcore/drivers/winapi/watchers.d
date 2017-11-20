module eventcore.drivers.winapi.watchers;

version (Windows):

import eventcore.driver;
import eventcore.drivers.winapi.core;
import eventcore.drivers.winapi.driver : WinAPIEventDriver; // FIXME: this is an ugly dependency
import eventcore.internal.win32;
import std.experimental.allocator : dispose, makeArray, theAllocator;


final class WinAPIEventDriverWatchers : EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	private {
		WinAPIEventDriverCore m_core;
	}

	this(WinAPIEventDriverCore core)
	{
		m_core = core;
	}

	override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback)
	{
		import std.utf : toUTF16z;
		auto handle = () @trusted {
			scope (failure) assert(false);
			return CreateFileW(path.toUTF16z, FILE_LIST_DIRECTORY,
				FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
				null, OPEN_EXISTING,
				FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
				null);
			} ();

		if (handle == INVALID_HANDLE_VALUE)
			return WatcherID.invalid;

		auto id = WatcherID(cast(int)handle);

		auto slot = m_core.setupSlot!WatcherSlot(handle);
		slot.directory = path;
		slot.recursive = recursive;
		slot.callback = callback;
		slot.buffer = () @trusted {
			try return theAllocator.makeArray!ubyte(16384);
			catch (Exception e) assert(false, "Failed to allocate directory watcher buffer.");
		} ();
		if (!triggerRead(handle, *slot)) {
			releaseRef(id);
			return WatcherID.invalid;
		}

		m_core.addWaiter();

		return id;
	}

	override void addRef(WatcherID descriptor)
	{
		m_core.m_handles[idToHandle(descriptor)].addRef();
	}

	override bool releaseRef(WatcherID descriptor)
	{
		auto handle = idToHandle(descriptor);
		return m_core.m_handles[handle].releaseRef(()nothrow{
			m_core.removeWaiter();
			CloseHandle(handle);
			() @trusted {
				try theAllocator.dispose(m_core.m_handles[handle].watcher.buffer);
				catch (Exception e) assert(false, "Freeing directory watcher buffer failed.");
			} ();
			m_core.freeSlot(handle);
		});
	}

	private static nothrow extern(System)
	void onIOCompleted(DWORD dwError, DWORD cbTransferred, OVERLAPPED* overlapped)
	{
		import std.conv : to;

		if (dwError != 0) {
			// FIXME: this must be propagated to the caller
			//logWarn("Failed to read directory changes: %s", dwError);
			return;
		}

		auto handle = overlapped.hEvent; // *file* handle
		auto id = WatcherID(cast(int)handle);

		/* HACK: this avoids a range voilation in case an already destroyed
			watcher still fires a completed event. It does not avoid problems
			that may arise from reused file handles.
		*/
		if (handle !in WinAPIEventDriver.threadInstance.core.m_handles)
			return;

		// NOTE: can be 0 if the buffer overflowed
		if (!cbTransferred)
			return;

		auto slot = () @trusted { return &WinAPIEventDriver.threadInstance.core.m_handles[handle].watcher(); } ();

		ubyte[] result = slot.buffer[0 .. cbTransferred];
		do {
			assert(result.length >= FILE_NOTIFY_INFORMATION._FileName.offsetof);
			auto fni = () @trusted { return cast(FILE_NOTIFY_INFORMATION*)result.ptr; } ();
			FileChange ch;
			switch (fni.Action) {
				default: ch.kind = FileChangeKind.modified; break;
				case 0x1: ch.kind = FileChangeKind.added; break;
				case 0x2: ch.kind = FileChangeKind.removed; break;
				case 0x3: ch.kind = FileChangeKind.modified; break;
				case 0x4: ch.kind = FileChangeKind.removed; break;
				case 0x5: ch.kind = FileChangeKind.added; break;
			}
			ch.directory = slot.directory;
			ch.isDirectory = false; // FIXME: is this right?
			ch.name = () @trusted { scope (failure) assert(false); return to!string(fni.FileName[0 .. fni.FileNameLength/2]); } ();
			slot.callback(id, ch);
			if (fni.NextEntryOffset == 0) break;
			result = result[fni.NextEntryOffset .. $];
		} while (result.length > 0);

		triggerRead(handle, *slot);
	}

	private static bool triggerRead(HANDLE handle, ref WatcherSlot slot)
	{
		enum UINT notifications = FILE_NOTIFY_CHANGE_FILE_NAME|
			FILE_NOTIFY_CHANGE_DIR_NAME|FILE_NOTIFY_CHANGE_SIZE|
			FILE_NOTIFY_CHANGE_LAST_WRITE;

		slot.overlapped.Internal = 0;
		slot.overlapped.InternalHigh = 0;
		slot.overlapped.Offset = 0;
		slot.overlapped.OffsetHigh = 0;
		slot.overlapped.hEvent = handle;

		BOOL ret;
		() @trusted {
			ret = ReadDirectoryChangesW(handle, slot.buffer.ptr, cast(DWORD)slot.buffer.length, slot.recursive,
				notifications, null, &slot.overlapped, &onIOCompleted);
		} ();

		if (!ret) {
			//logError("Failed to read directory changes in '%s'", m_path);
			return false;
		}
		return true;
	}

	static private HANDLE idToHandle(WatcherID id) @trusted { return cast(HANDLE)cast(int)id; }
}
