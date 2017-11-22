module eventcore.drivers.posix.watchers;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;


final class InotifyEventDriverWatchers(Events : EventDriverEvents) : EventDriverWatchers
{
	import core.stdc.errno : errno, EAGAIN, EINPROGRESS;
	import core.sys.posix.fcntl, core.sys.posix.unistd, core.sys.linux.sys.inotify;
	import std.algorithm.comparison : among;
	import std.file;

	private {
		alias Loop = typeof(Events.init.loop);
		Loop m_loop;

		struct WatchState {
			string[int] watcherPaths;
			string basePath;
			bool recursive;
		}

		WatchState[WatcherID] m_watches; // TODO: use a @nogc (allocator based) map
	}

	this(Events events) { m_loop = events.loop; }

	final override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback)
	{
		import std.path : buildPath, pathSplitter;
		import std.range : drop;
		import std.range.primitives : walkLength;

		enum IN_NONBLOCK = 0x800; // value in core.sys.linux.sys.inotify is incorrect
		auto handle = () @trusted { return inotify_init1(IN_NONBLOCK); } ();
		if (handle == -1) return WatcherID.invalid;

		auto ret = WatcherID(handle);

		m_watches[ret] = WatchState(null, path, recursive);

		addWatch(ret, path, "");
		if (recursive) {
			try {
				auto base_segements = path.pathSplitter.walkLength;
				if (path.isDir) () @trusted {
					foreach (de; path.dirEntries(SpanMode.depth))
						if (de.isDir) {
							auto subdir = de.name.pathSplitter.drop(base_segements).buildPath;
							addWatch(ret, path, subdir);
						}
				} ();
			} catch (Exception e) {
				// TODO: decide if this should be ignored or if the error should be forwarded
			}
		}

		m_loop.initFD(FD(handle), FDFlags.none);
		m_loop.registerFD(FD(handle), EventMask.read);
		m_loop.setNotifyCallback!(EventType.read)(FD(handle), &onChanges);
		m_loop.m_fds[handle].specific = WatcherSlot(callback);

		processEvents(WatcherID(handle));

		return ret;
	}

	final override void addRef(WatcherID descriptor)
	{
		assert(m_loop.m_fds[descriptor].common.refCount > 0, "Adding reference to unreferenced event FD.");
		m_loop.m_fds[descriptor].common.refCount++;
	}

	final override bool releaseRef(WatcherID descriptor)
	{
		FD fd = cast(FD)descriptor;
		assert(m_loop.m_fds[fd].common.refCount > 0, "Releasing reference to unreferenced event FD.");
		if (--m_loop.m_fds[fd].common.refCount == 1) { // NOTE: 1 because setNotifyCallback increments the reference count
			m_loop.unregisterFD(fd, EventMask.read);
			m_loop.clearFD(fd);
			m_watches.remove(descriptor);
			/*errnoEnforce(*/close(cast(int)fd)/* == 0)*/;
			return false;
		}

		return true;
	}

	private void onChanges(FD fd)
	{
		processEvents(cast(WatcherID)fd);
	}

	private void processEvents(WatcherID id)
	{
		import std.path : buildPath, dirName;
		import core.stdc.stdio : FILENAME_MAX;
		import core.stdc.string : strlen;

		ubyte[inotify_event.sizeof + FILENAME_MAX + 1] buf = void;
		while (true) {
			auto ret = () @trusted { return read(cast(int)id, &buf[0], buf.length); } ();

			if (ret == -1 && errno.among!(EAGAIN, EINPROGRESS))
				break;
			assert(ret <= buf.length);

			auto w = m_watches[id];

			auto rem = buf[0 .. ret];
			while (rem.length > 0) {
				auto ev = () @trusted { return cast(inotify_event*)rem.ptr; } ();
				rem = rem[inotify_event.sizeof + ev.len .. $];

				// is the watch already deleted?
				if (ev.mask & IN_IGNORED) continue;

				FileChange ch;
				if (ev.mask & (IN_CREATE|IN_MOVED_TO))
					ch.kind = FileChangeKind.added;
				else if (ev.mask & (IN_DELETE|IN_DELETE_SELF|IN_MOVE_SELF|IN_MOVED_FROM))
					ch.kind = FileChangeKind.removed;
				else if (ev.mask & IN_MODIFY)
					ch.kind = FileChangeKind.modified;

				if (ev.mask & IN_DELETE_SELF) {
					() @trusted { inotify_rm_watch(cast(int)id, ev.wd); } ();
					w.watcherPaths.remove(ev.wd);
					continue;
				} else if (ev.mask & IN_MOVE_SELF) {
					// NOTE: the should have been updated by a previous IN_MOVED_TO
					continue;
				}

				auto name = () @trusted { return ev.name.ptr[0 .. strlen(ev.name.ptr)]; } ();
				auto subdir = w.watcherPaths[ev.wd];

				if (w.recursive && ev.mask & (IN_CREATE|IN_MOVED_TO) && ev.mask & IN_ISDIR) {
					addWatch(id, w.basePath, subdir == "" ? name.idup : buildPath(subdir, name));
				}

				ch.baseDirectory = m_watches[id].basePath;
				ch.directory = subdir;
				ch.isDirectory = (ev.mask & IN_ISDIR) != 0;
				ch.name = name;
				addRef(id); // assure that the id doesn't get invalidated until after the callback
				auto cb = m_loop.m_fds[id].watcher.callback;
				cb(id, ch);
				if (!releaseRef(id)) return;
			}
		}
	}

	private bool addWatch(WatcherID handle, string base_path, string path)
	{
		import std.path : buildPath;
		import std.string : toStringz;

		enum EVENTS = IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MODIFY |
			IN_MOVE_SELF | IN_MOVED_FROM | IN_MOVED_TO;
		immutable wd = () @trusted { return inotify_add_watch(cast(int)handle, buildPath(base_path, path).toStringz, EVENTS); } ();
		if (wd == -1) return false;
		m_watches[handle].watcherPaths[wd] = path;
		return true;
	}
}

version (OSX)
final class FSEventsEventDriverWatchers(Events : EventDriverEvents) : EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	private Events m_events;

	this(Events events) { m_events = events; }

	final override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback on_change)
	{
		/*FSEventStreamCreate
		FSEventStreamScheduleWithRunLoop
		FSEventStreamStart*/
		assert(false, "TODO!");
	}

	final override void addRef(WatcherID descriptor)
	{
		assert(false, "TODO!");
	}

	final override bool releaseRef(WatcherID descriptor)
	{
		/*FSEventStreamStop
		FSEventStreamUnscheduleFromRunLoop
		FSEventStreamInvalidate
		FSEventStreamRelease*/
		assert(false, "TODO!");
	}
}


/** Generic directory watcher implementation based on periodic directory
	scanning.

	Note that this implementation, although it works on all operating systems,
	is not efficient for directories with many files, since it has to keep a
	representation of the whole directory in memory and needs to list all files
	for each polling period, which can result in excessive hard disk activity.
*/
final class PollEventDriverWatchers(Events : EventDriverEvents) : EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	import core.thread : Thread;
	import core.sync.mutex : Mutex;

	private {
		Events m_events;
		PollingThread[EventID] m_pollers;
	}

	this(Events events) { m_events = events; }

	final override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback on_change)
	{
		import std.file : exists, isDir;

		// validate base directory
		try if (!isDir(path)) return WatcherID.invalid;
		catch (Exception e) return WatcherID.invalid;

		// create event to wait on for new changes
		auto evt = m_events.create();
		assert(evt !is EventID.invalid, "Failed to create event.");
		auto pt = new PollingThread(() @trusted { return cast(shared)m_events; } (), evt, path, recursive, on_change);
		m_pollers[evt] = pt;
		try () @trusted { pt.isDaemon = true; } ();
		catch (Exception e) assert(false, e.msg);
		() @trusted { pt.start(); } ();

		m_events.wait(evt, &onEvent);

		return cast(WatcherID)evt;
	}

	final override void addRef(WatcherID descriptor)
	{
		assert(descriptor != WatcherID.invalid);
		auto evt = cast(EventID)descriptor;
		auto pt = evt in m_pollers;
		assert(pt !is null);
		m_events.addRef(evt);
	}

	final override bool releaseRef(WatcherID descriptor)
	{
		assert(descriptor != WatcherID.invalid);
		auto evt = cast(EventID)descriptor;
		auto pt = evt in m_pollers;
		assert(pt !is null);
		if (!m_events.releaseRef(evt)) {
			pt.dispose();
			return false;
		}
		return true;
	}

	private void onEvent(EventID evt)
	{
		import std.algorithm.mutation : swap;

		auto pt = evt in m_pollers;
		if (!pt) return;

		m_events.wait(evt, &onEvent);

		FileChange[] changes;
		try synchronized (pt.m_changesMutex)
			swap(changes, pt.m_changes);
		catch (Exception e) assert(false, "Failed to acquire mutex: "~e.msg);

		foreach (ref ch; changes)
			pt.m_callback(cast(WatcherID)evt, ch);
	}

	private final class PollingThread : Thread {
		int refCount = 1;
		EventID changesEvent;

		private {
			shared(Events) m_eventsDriver;
			Mutex m_changesMutex;
			/*shared*/ FileChange[] m_changes;
			immutable string m_basePath;
			immutable bool m_recursive;
			immutable FileChangesCallback m_callback;
			shared bool m_shutdown = false;
			size_t m_entryCount;

			struct Entry {
				Entry* parent;
				string name;
				ulong size;
				long lastChange;

				string path()
				{
					import std.path : buildPath;
					if (parent)
						return buildPath(parent.path, name);
					else return name;
				}

				bool isDir() const { return size == ulong.max; }
			}

			struct Key {
				Entry* parent;
				string name;
			}

			Entry*[Key] m_entries;
		}

		this(shared(Events) event_driver, EventID event, string path, bool recursive, FileChangesCallback callback)
		@trusted nothrow {
			import core.time : seconds;

			m_changesMutex = new Mutex;
			m_eventsDriver = event_driver;
			changesEvent = event;
			m_basePath = path;
			m_recursive = recursive;
			m_callback = callback;
			scan(false);

			try super(&run);
			catch (Exception e) assert(false, e.msg);
		}

		void dispose()
		nothrow {
			import core.atomic : atomicStore;

			try synchronized (m_changesMutex) {
				changesEvent = EventID.invalid;
			} catch (Exception e) assert(false, e.msg);
		}

		private void run()
		nothrow @trusted {
			import core.atomic : atomicLoad;
			import core.time : msecs;
			import std.algorithm.comparison : min;

			try while (true) {
				() @trusted { Thread.sleep(min(m_entryCount, 60000).msecs + 1000.msecs); } ();

				try synchronized (m_changesMutex) {
					if (changesEvent == EventID.invalid) break;
				} catch (Exception e) assert(false, "Mutex lock failed: "~e.msg);

				scan(true);

				try synchronized (m_changesMutex) {
					if (changesEvent == EventID.invalid) break;
					if (m_changes.length)
						m_eventsDriver.trigger(changesEvent, false);
				} catch (Exception e) assert(false, "Mutex lock failed: "~e.msg);
			} catch (Throwable th) {
				import core.stdc.stdio : fprintf, stderr;
				import core.stdc.stdlib : abort;

				fprintf(stderr, "Fatal error: %.*s\n", th.msg.length, th.msg.ptr);
				abort();
			}
		}

		private void addChange(FileChangeKind kind, Key key, bool is_dir)
		{
			try synchronized (m_changesMutex) {
				m_changes ~= FileChange(kind, m_basePath, key.parent ? key.parent.path : ".", key.name, is_dir);
			} catch (Exception e) assert(false, "Mutex lock failed: "~e.msg);
		}

		private void scan(bool generate_changes)
		@trusted nothrow {
			import std.algorithm.mutation : swap;

			Entry*[Key] new_entries;
			size_t ec = 0;

			scan(null, generate_changes, new_entries, ec);

			foreach (e; m_entries.byKeyValue) {
				if (!e.key.parent || Key(e.key.parent.parent, e.key.parent.name) !in m_entries) {
					if (generate_changes)
						addChange(FileChangeKind.removed, e.key, e.value.isDir);
				}
				delete e.value;
			}

			swap(m_entries, new_entries);
			m_entryCount = ec;
		}

		private void scan(Entry* parent, bool generate_changes, ref Entry*[Key] new_entries, ref size_t ec)
		@trusted nothrow {
			import std.file : SpanMode, dirEntries;
			import std.path : buildPath, baseName;

			auto ppath = parent ? buildPath(m_basePath, parent.path) : m_basePath;
			try foreach (de; dirEntries(ppath, SpanMode.shallow)) {
				auto key = Key(parent, de.name.baseName);
				auto modified_time = de.timeLastModified.stdTime;
				if (auto pe = key in m_entries) {
					if ((*pe).isDir) {
						if (m_recursive)
							scan(*pe, generate_changes, new_entries, ec);
					} else {
						if ((*pe).size != de.size || (*pe).lastChange != modified_time) {
							if (generate_changes)
								addChange(FileChangeKind.modified, key, (*pe).isDir);
							(*pe).size = de.size;
							(*pe).lastChange = modified_time;
						}
					}

					new_entries[key] = *pe;
					ec++;
					m_entries.remove(key);
				} else {
					auto e = new Entry(parent, key.name, de.isDir ? ulong.max : de.size, modified_time);
					new_entries[key] = e;
					ec++;
					if (generate_changes)
						addChange(FileChangeKind.added, key, e.isDir);

					if (de.isDir && m_recursive) scan(e, false, new_entries, ec);
				}
			} catch (Exception e) {} // will result in all children being flagged as removed
		}
	}
}

package struct WatcherSlot {
	alias Handle = WatcherID;
	FileChangesCallback callback;
}
