/**
	Efficient generic management of large numbers of timers.
*/
module eventcore.drivers.timer;

import eventcore.driver;


mixin template DefaultTimerImpl() {
	import std.experimental.allocator.building_blocks.free_list;
	import std.experimental.allocator.building_blocks.region;
	import std.experimental.allocator.mallocator;
	import std.experimental.allocator : dispose, make;
	import std.container.array;
	import std.datetime : Clock;
	import std.range : SortedRange, assumeSorted, take;
	import core.time : hnsecs, Duration;

	private {
		static FreeList!(Mallocator, TimerSlot.sizeof) ms_allocator;
		TimerSlot*[TimerID] m_timers;
		Array!(TimerSlot*) m_timerQueue;
		TimerID m_lastTimerID;
		TimerSlot*[] m_firedTimers;
	}

	static this()
	{
		ms_allocator.parent = Mallocator.instance;
	}

	final protected Duration getNextTimeout(long stdtime)
	{
		return m_timerQueue.length ? (m_timerQueue.front.timeout - stdtime).hnsecs : Duration.max;
	}

	final protected bool processTimers(long stdtime)
	@trusted nothrow {
		assert(m_firedTimers.length == 0);
		if (m_timerQueue.empty) return false;

		TimerSlot ts = void;
		ts.timeout = stdtime+1;
		auto fired = m_timerQueue[].assumeSorted!((a, b) => a.timeout < b.timeout).lowerBound(&ts);
		foreach (tm; fired) {
			if (tm.repeatDuration > 0) {
				do tm.timeout += tm.repeatDuration;
				while (tm.timeout <= stdtime);
				auto tail = m_timerQueue[fired.length .. $].assumeSorted!((a, b) => a.timeout < b.timeout).upperBound(tm);
				try m_timerQueue.insertBefore(tail.release, tm);
				catch (Exception e) { print("Failed to insert timer: %s", e.msg); }
			} else tm.pending = false;
			m_firedTimers ~= tm;
		}

		// NOTE: this isn't yet verified to work under all circumstances
		auto elems = m_timerQueue[0 .. fired.length];
		scope (failure) assert(false);
		m_timerQueue.linearRemove(elems);

		foreach (tm; m_firedTimers)
			foreach (cb; tm.callbacks)
				cb(tm.id);
		
		bool any_fired = m_firedTimers.length > 0;

		m_firedTimers.length = 0;
		m_firedTimers.assumeSafeAppend();

		return any_fired;
	}

	final override TimerID createTimer()
	@trusted {
		auto id = cast(TimerID)(m_lastTimerID + 1);
		TimerSlot* tm;
		try tm = ms_allocator.make!TimerSlot;
		catch (Exception e) return TimerID.invalid;
		assert(tm !is null);
		tm.id = id;
		tm.refCount = 1;
		m_timers[id] = tm;
		return id;
	}

	final override void setTimer(TimerID timer, Duration timeout, Duration repeat)
	@trusted {
		scope (failure) assert(false);
		auto tm = m_timers[timer];
		if (tm.pending) stopTimer(timer);
		tm.timeout = Clock.currStdTime + timeout.total!"hnsecs";
		tm.repeatDuration = repeat.total!"hnsecs";
		tm.pending = true;

		auto largerRange = m_timerQueue[].assumeSorted!((a, b) => a.timeout < b.timeout).upperBound(tm);
		try m_timerQueue.insertBefore(largerRange.release, tm);
		catch (Exception e) { print("Failed to insert timer: %s", e.msg); }
	}

	final override void stopTimer(TimerID timer)
	@trusted {
		auto tm = m_timers[timer];
		if (!tm.pending) return;
		tm.pending = false;
		tm.callbacks.length = 0;

		TimerSlot cmp = void;
		cmp.timeout = tm.timeout-1;
		auto upper = m_timerQueue[].assumeSorted!((a, b) => a.timeout < b.timeout).upperBound(&cmp);
		assert(!upper.empty);
		while (!upper.empty) {
			assert(upper.front.timeout == tm.timeout);
			if (upper.front is tm) {
				scope (failure) assert(false);
				m_timerQueue.linearRemove(upper.release.take(1));
				break;
			}
		}
	}

	final override bool isTimerPending(TimerID descriptor)
	{
		return m_timers[descriptor].pending;
	}

	final override bool isTimerPeriodic(TimerID descriptor)
	{
		return m_timers[descriptor].repeatDuration > 0;
	}

	final override void waitTimer(TimerID timer, TimerCallback callback)
	{
		m_timers[timer].callbacks ~= callback;
	}

	final override void cancelTimerWait(TimerID timer, TimerCallback callback)
	{
		import std.algorithm.mutation : remove;
		import std.algorithm.searching : countUntil;

		auto pt = m_timers[timer];
		auto idx = pt.callbacks.countUntil(callback);
		if (idx >= 0) pt.callbacks = pt.callbacks.remove(idx);
	}

	final override void addRef(TimerID descriptor)
	{
		m_timers[descriptor].refCount++;
	}

	final override void releaseRef(TimerID descriptor)
	{
		auto tm = m_timers[descriptor];
		if (!--tm.refCount) {
			if (tm.pending) stopTimer(tm.id);
			m_timers.remove(descriptor);
			() @trusted { scope (failure) assert(false); ms_allocator.dispose(tm); } ();
		}
	}
}

struct TimerSlot {
	TimerID id;
	uint refCount;
	bool pending;
	long timeout; // stdtime
	long repeatDuration;
	TimerCallback[] callbacks; // TODO: use a list with small-value optimization
}
