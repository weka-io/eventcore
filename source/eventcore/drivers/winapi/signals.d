module eventcore.drivers.winapi.signals;

version (Windows):

import eventcore.driver;
import eventcore.internal.win32;


final class WinAPIEventDriverSignals : EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	override SignalListenID listen(int sig, SignalCallback on_signal)
	{
		assert(false, "TODO!");
	}

	override bool isValid(SignalListenID handle)
	const {
		return false;
	}

	override void addRef(SignalListenID descriptor)
	{
		if (!isValid(descriptor)) return;

		assert(false, "TODO!");
	}

	override bool releaseRef(SignalListenID descriptor)
	{
		if (!isValid(descriptor)) return true;

		assert(false, "TODO!");
	}
}
