EventCore
=========

This is a high-performance native event loop abstraction for D, focused on asynchronous I/O and GUI message integration. The API is callback (delegate) based. For a higher level fiber based abstraction, take a look at [vibe.d](https://vibed.org/).

[![Build Status](https://travis-ci.org/vibe-d/eventcore.svg?branch=master)](https://travis-ci.org/vibe-d/eventcore)


Supported drivers and operating systems
---------------------------------------

Driver            | Linux   | Windows | macOS   | FreeBSD
------------------|---------|---------|---------|--------
SelectEventDriver | yes     | yes     | yes¹    | yes¹
EpollEventDriver  | yes     | &mdash; | &mdash; | &mdash;
WinAPIEventDriver | &mdash; | yes     | &mdash; | &mdash;
KqueueEventDriver | &mdash; | &mdash; | yes¹    | yes¹

¹ planned, but not currenly implemented


Driver development status
-------------------------

Feature          | SelectEventDriver | EpollEventDriver | WinAPIEventDriver | KqueueEventDriver
-----------------|-------------------|------------------|-------------------|------------------
TCP Sockets      | yes               | yes              | &mdash;           | &mdash;          
UDP Sockets      | yes               | yes              | &mdash;           | &mdash;          
USDS             | yes               | yes              | &mdash;           | &mdash;          
DNS              | yes               | yes              | &mdash;           | &mdash;          
Timers           | yes               | yes              | yes               | &mdash;          
Events           | yes               | yes              | yes               | &mdash;          
Unix Signals     | yes²              | yes²             | &mdash;           | &mdash;          
Files            | yes               | yes              | yes               | &mdash;          
UI Integration   | &mdash;           | &mdash;          | yes               | &mdash;          
File watcher     | yes²              | yes²             | yes               | &mdash;          

² Currently only supported on Linux


Open questions
--------------

- Error code reporting
- Adopting existing file descriptors (done for files)
- Enqueued writes
