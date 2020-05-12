module eventcore.drivers.winapi.pipes;

version (Windows):

import eventcore.driver;
import eventcore.internal.win32;

final class WinAPIEventDriverPipes : EventDriverPipes {
@safe: /*@nogc:*/ nothrow:
	override PipeFD adopt(int system_pipe_handle)
	{
		assert(false, "TODO!");
	}

	override void read(PipeFD pipe, ubyte[] buffer, IOMode mode, PipeIOCallback on_read_finish)
	{
		if (!isValid(pipe)) {
			on_read_finish(pipe, IOStatus.invalidHandle, 0);
			return;
		}

		assert(false, "TODO!");
	}

	override void cancelRead(PipeFD pipe)
	{
		if (!isValid(pipe)) return;

		assert(false, "TODO!");
	}

	override void write(PipeFD pipe, const(ubyte)[] buffer, IOMode mode, PipeIOCallback on_write_finish)
	{
		if (!isValid(pipe)) {
			on_write_finish(pipe, IOStatus.invalidHandle, 0);
			return;
		}

		assert(false, "TODO!");
	}

	override void cancelWrite(PipeFD pipe)
	{
		if (!isValid(pipe)) return;

		assert(false, "TODO!");
	}

	override void waitForData(PipeFD pipe, PipeIOCallback on_data_available)
	{
		if (!isValid(pipe)) return;

		assert(false, "TODO!");
	}

	override void close(PipeFD pipe, PipeCloseCallback on_closed)
	{
		if (!isValid(pipe)) {
			if (on_closed)
				on_closed(pipe, CloseStatus.invalidHandle);
			return;
		}

		assert(false, "TODO!");
	}

	override bool isValid(PipeFD handle)
	const {
		return false;
	}

	override void addRef(PipeFD pipe)
	{
    	if (!isValid(pipe)) return;

		assert(false, "TODO!");
	}

	override bool releaseRef(PipeFD pipe)
	{
    	if (!isValid(pipe)) return true;

		assert(false, "TODO!");
	}

	protected override void* rawUserData(PipeFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		assert(false, "TODO!");
	}
}
