module eventcore.drivers.posix.processes;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.drivers.posix.signals;
import eventcore.internal.utils : nogc_assert, print;

import std.algorithm.comparison : among;
import std.variant : visit;

private struct ProcessInfo {
    bool exited = true;
    int exitCode;
    ProcessWaitCallback[] callbacks;
    size_t refCount = 0;
    EventDriverProcesses driver;

    DataInitializer userDataDestructor;
    ubyte[16*size_t.sizeof] userData;
}

private struct StaticProcesses {
@safe: nothrow:
    import core.sync.mutex : Mutex;

    private {
        static shared Mutex m_mutex;
        static __gshared ProcessInfo[ProcessID] m_processes;
    }

    shared static this()
    {
        m_mutex = new shared Mutex;
    }

    static void add(ProcessID pid, ProcessInfo info) @trusted {
        m_mutex.lock_nothrow();
        scope (exit) m_mutex.unlock_nothrow();

        assert(pid !in m_processes, "Process adopted twice");
        m_processes[pid] = info;
    }
}

private auto lockedProcessInfo(alias fn)(ProcessID pid) @trusted {
    StaticProcesses.m_mutex.lock_nothrow();
    scope (exit) StaticProcesses.m_mutex.unlock_nothrow();
    auto info = pid in StaticProcesses.m_processes;

    return fn(info);
}


private enum SIGCHLD = 17;

final class SignalEventDriverProcesses(Loop : PosixEventLoop) : EventDriverProcesses {
@safe: /*@nogc:*/ nothrow:
    import core.stdc.errno : errno, EAGAIN, EINPROGRESS;
    import core.sys.linux.sys.signalfd;
    import core.sys.posix.unistd : close, read, write, dup;

    private {
        Loop m_loop;
        EventDriver m_driver;
        SignalListenID m_sighandle;
    }

    this(Loop loop, EventDriver driver)
    {
        import core.sys.posix.signal;

        m_loop = loop;
        m_driver = driver;

        // Listen for child process exits using SIGCHLD
        m_sighandle = () @trusted {
            sigset_t sset;
            sigemptyset(&sset);
            sigaddset(&sset, SIGCHLD);

            assert(sigprocmask(SIG_BLOCK, &sset, null) == 0);

            return SignalListenID(signalfd(-1, &sset, SFD_NONBLOCK | SFD_CLOEXEC));
        } ();

        m_loop.initFD(cast(FD)m_sighandle, FDFlags.internal, SignalSlot(null));
        m_loop.registerFD(cast(FD)m_sighandle, EventMask.read);
        m_loop.setNotifyCallback!(EventType.read)(cast(FD)m_sighandle, &onSignal);

        onSignal(cast(FD)m_sighandle);
    }

    void dispose()
    {
        FD sighandle = cast(FD)m_sighandle;
        m_loop.m_fds[sighandle].common.refCount--;
        m_loop.setNotifyCallback!(EventType.read)(sighandle, null);
        m_loop.unregisterFD(sighandle, EventMask.read|EventMask.write|EventMask.status);
        m_loop.clearFD!(SignalSlot)(sighandle);
        close(cast(int)sighandle);
    }

    final override ProcessID adopt(int system_pid)
    {
        auto pid = cast(ProcessID)system_pid;

        ProcessInfo info;
        info.exited = false;
        info.refCount = 1;
        info.driver = this;
        StaticProcesses.add(pid, info);

        return pid;
    }

    final override Process spawn(
        string[] args,
        ProcessStdinFile stdin,
        ProcessStdoutFile stdout,
        ProcessStderrFile stderr,
        const string[string] env,
        ProcessConfig config,
        string working_dir)
    @trusted {
        // Use std.process to spawn processes
        import std.process : pipe, Pid, spawnProcess;
        import std.stdio : File;
        static import std.stdio;

        static File fdToFile(int fd, scope const(char)[] mode)
        {
            try {
                File f;
                f.fdopen(fd, mode);
                return f;
            } catch (Exception e) {
                assert(0);
            }
        }

        try {
            Process process;
            File stdinFile, stdoutFile, stderrFile;

            stdinFile = stdin.visit!(
                (int handle) => fdToFile(handle, "r"),
                (ProcessRedirect redirect) {
                    final switch (redirect) {
                    case ProcessRedirect.inherit: return std.stdio.stdin;
                    case ProcessRedirect.none: return File.init;
                    case ProcessRedirect.pipe:
                        auto p = pipe();
                        process.stdin = m_driver.pipes.adopt(dup(p.writeEnd.fileno));
                        return p.readEnd;
                    }
                });

            stdoutFile = stdout.visit!(
                (int handle) => fdToFile(handle, "w"),
                (ProcessRedirect redirect) {
                    final switch (redirect) {
                    case ProcessRedirect.inherit: return std.stdio.stdout;
                    case ProcessRedirect.none: return File.init;
                    case ProcessRedirect.pipe:
                        auto p = pipe();
                        process.stdout = m_driver.pipes.adopt(dup(p.readEnd.fileno));
                        return p.writeEnd;
                    }
                },
                (_) => File.init);

            stderrFile = stderr.visit!(
                (int handle) => fdToFile(handle, "w"),
                (ProcessRedirect redirect) {
                    final switch (redirect) {
                    case ProcessRedirect.inherit: return std.stdio.stderr;
                    case ProcessRedirect.none: return File.init;
                    case ProcessRedirect.pipe:
                        auto p = pipe();
                        process.stderr = m_driver.pipes.adopt(dup(p.readEnd.fileno));
                        return p.writeEnd;
                    }
                },
                (_) => File.init);

            const redirectStdout = stdout.convertsTo!ProcessStdoutRedirect;
            const redirectStderr = stderr.convertsTo!ProcessStderrRedirect;

            if (redirectStdout) {
                assert(!redirectStderr, "Can't redirect both stdout and stderr");

                stdoutFile = stderrFile;
            } else if (redirectStderr) {
                stderrFile = stdoutFile;
            }

            Pid stdPid = spawnProcess(
                args,
                stdinFile,
                stdoutFile,
                stderrFile,
                env,
                cast(std.process.Config)config,
                working_dir);
            process.pid = adopt(stdPid.osHandle);
            stdPid.destroy();

            return process;
        } catch (Exception e) {
            return Process.init;
        }
    }

    final override void kill(ProcessID pid, int signal)
    @trusted {
        import core.sys.posix.signal : pkill = kill;

        pkill(cast(int)pid, signal);
    }

    final override size_t wait(ProcessID pid, ProcessWaitCallback on_process_exit)
    {
        bool exited;
        int exitCode;

        size_t id = lockedProcessInfo!((info) {
            assert(info !is null, "Unknown process ID");

            if (info.exited) {
                exited = true;
                exitCode = info.exitCode;
                return 0;
            } else {
                info.callbacks ~= on_process_exit;
                return info.callbacks.length - 1;
            }
        })(pid);

        if (exited) {
            on_process_exit(pid, exitCode);
        }

        return id;
    }

    final override void cancelWait(ProcessID pid, size_t waitId)
    {
        lockedProcessInfo!((info) {
            assert(info !is null, "Unknown process ID");
            assert(!info.exited, "Cannot cancel wait when none are pending");
            assert(info.callbacks.length > waitId, "Invalid process wait ID");

            info.callbacks[waitId] = null;
        })(pid);
    }

    private void onSignal(FD fd)
    {
        SignalListenID lid = cast(SignalListenID)fd;

        signalfd_siginfo nfo;
        do {
            auto ret = () @trusted { return read(cast(int)fd, &nfo, nfo.sizeof); } ();

            if (ret == -1 && errno.among!(EAGAIN, EINPROGRESS) || ret != nfo.sizeof)
                return;

            onProcessExit(nfo.ssi_pid, nfo.ssi_status);
        } while (true);
    }

    private void onProcessExit(int system_pid, int exitCode)
    {
        auto pid = cast(ProcessID)system_pid;

        ProcessWaitCallback[] callbacks;
        auto driver = lockedProcessInfo!((info) @safe {
            // We get notified of any child exiting, so ignore the ones we're
            // not aware of
            if (info is null) {
                return null;
            }

            // Increment the ref count to make sure it doesn't get removed
            info.refCount++;

            info.exited = true;
            info.exitCode = exitCode;
            return info.driver;
        })(pid);

        // Need to call callbacks in the owner thread as this function can be
        // called from any thread. Without extra threads this is always the main
        // thread.
        if (() @trusted { return cast(void*)this == cast(void*)driver; } ()) {
            onLocalProcessExit(cast(intptr_t)pid);
        } else {
            auto sharedDriver = () @trusted { return cast(shared typeof(this))driver; } ();

            sharedDriver.m_driver.core.runInOwnerThread(&onLocalProcessExit, cast(intptr_t)pid);
        }
    }

    private static void onLocalProcessExit(intptr_t system_pid)
    {
        auto pid = cast(ProcessID)system_pid;

        int exitCode;
        ProcessWaitCallback[] callbacks;

        auto driver = lockedProcessInfo!((info) {
            assert(info !is null);

            exitCode = info.exitCode;

            callbacks = info.callbacks;
            info.callbacks = null;

            return info.driver;
        })(pid);

        foreach (cb; callbacks) {
            if (cb)
                cb(pid, exitCode);
        }

        driver.releaseRef(pid);
    }

    final override bool hasExited(ProcessID pid)
    {
        return lockedProcessInfo!((info) {
            assert(info !is null, "Unknown process ID");

            return info.exited;
        })(pid);
    }

    final override void addRef(ProcessID pid)
    {
        lockedProcessInfo!((info) {
            nogc_assert(info.refCount > 0, "Adding reference to unreferenced process FD.");
            info.refCount++;
        })(pid);
    }

    final override bool releaseRef(ProcessID pid)
    {
        return lockedProcessInfo!((info) {
            nogc_assert(info.refCount > 0, "Releasing reference to unreferenced process FD.");
            if (--info.refCount == 0) {
                // Remove/deallocate process
                if (info.userDataDestructor)
                    () @trusted { info.userDataDestructor(info.userData.ptr); } ();

                StaticProcesses.m_processes.remove(pid);
                return false;
            }
            return true;
        })(pid);
    }

    final protected override void* rawUserData(ProcessID pid, size_t size, DataInitializer initialize, DataInitializer destroy)
    @system {
        return lockedProcessInfo!((info) {
            assert(info.userDataDestructor is null || info.userDataDestructor is destroy,
                "Requesting user data with differing type (destructor).");
            assert(size <= ProcessInfo.userData.length, "Requested user data is too large.");

            if (!info.userDataDestructor) {
                initialize(info.userData.ptr);
                info.userDataDestructor = destroy;
            }
            return info.userData.ptr;
        })(pid);
    }

    package final @property size_t pendingCount() const nothrow @trusted { return StaticProcesses.m_processes.length; }
}

final class DummyEventDriverProcesses(Loop : PosixEventLoop) : EventDriverProcesses {
@safe: /*@nogc:*/ nothrow:

    this(Loop loop, EventDriver driver) {}

    void dispose() {}

    override ProcessID adopt(int system_pid)
    {
        assert(false, "TODO!");
    }

    override Process spawn(string[] args, ProcessStdinFile stdin, ProcessStdoutFile stdout, ProcessStderrFile stderr, const string[string] env, ProcessConfig config, string working_dir)
    {
        assert(false, "TODO!");
    }

    override bool hasExited(ProcessID pid)
    {
        assert(false, "TODO!");
    }

    override void kill(ProcessID pid, int signal)
    {
        assert(false, "TODO!");
    }

    override size_t wait(ProcessID pid, ProcessWaitCallback on_process_exit)
    {
        assert(false, "TODO!");
    }

    override void cancelWait(ProcessID pid, size_t waitId)
    {
        assert(false, "TODO!");
    }

    override void addRef(ProcessID pid)
    {
        assert(false, "TODO!");
    }

    override bool releaseRef(ProcessID pid)
    {
        assert(false, "TODO!");
    }

    protected override void* rawUserData(ProcessID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
    @system {
        assert(false, "TODO!");
    }

    package final @property size_t pendingCount() const nothrow { return 0; }
}
