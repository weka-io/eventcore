/** Provides a shared task pool for distributing tasks to worker threads.
*/
module eventcore.internal.ioworker;

import eventcore.internal.utils;

import std.parallelism : TaskPool, Task, task;


IOWorkerPool acquireIOWorkerPool()
@safe nothrow {
	return IOWorkerPool(true);
}

struct IOWorkerPool {
	private {
		TaskPool m_pool;
	}

	@safe nothrow:

	private this(bool) { m_pool = StaticTaskPool.addRef(); }
	~this() { if (m_pool) StaticTaskPool.releaseRef(); }
	this(this) { if (m_pool) StaticTaskPool.addRef(); }

	bool opCast(T)() const if (is(T == bool)) { return !!m_pool; }

	@property TaskPool pool() { return m_pool; }

	alias pool this;

	auto run(alias fun, ARGS...)(ARGS args)
	{
		auto t = task!(fun, ARGS)(args);
		try m_pool.put(t);
		catch (Exception e) assert(false, e.msg);
		return t;
	}
}

// Maintains a single thread pool shared by all driver instances (threads)
private struct StaticTaskPool {
	import core.sync.mutex : Mutex;

	private {
		static shared Mutex m_mutex;
		static __gshared TaskPool m_pool;
		static __gshared int m_refCount = 0;
	}

	shared static this()
	{
		m_mutex = new shared Mutex;
	}

	static TaskPool addRef()
	@trusted nothrow {
		m_mutex.lock_nothrow();
		scope (exit) m_mutex.unlock_nothrow();

		if (!m_refCount++) {
			try {
				m_pool = mallocT!TaskPool(4);
				m_pool.isDaemon = true;
			} catch (Exception e) {
				assert(false, e.msg);
			}
		}

		return m_pool;
	}

	static void releaseRef()
	@trusted nothrow {
		TaskPool fin_pool;

		{
			m_mutex.lock_nothrow();
			scope (exit) m_mutex.unlock_nothrow();

			if (!--m_refCount) {
				fin_pool = m_pool;
				m_pool = null;
			}
		}

		if (fin_pool) {
			//log("finishing thread pool");
			try {
				fin_pool.finish(true);
				freeT(fin_pool);
			} catch (Exception e) {
				//log("Failed to shut down file I/O thread pool.");
			}
		}
	}
}
