EventCore
=========

This is a high-performance native event loop abstraction for D, focused on asynchronous I/O and GUI message integration. The API is callback (delegate) based. For a higher level fiber based abstraction, take a look at [vibe.d](https://vibed.org/).

[![Build Status](https://travis-ci.org/vibe-d/eventcore.svg?branch=master)](https://travis-ci.org/vibe-d/eventcore)


Supported drivers and operating systems
---------------------------------------

Driver            | Linux | Windows | OS X | FreeBSD
------------------|-------|---------|------|--------
SelectEventDriver | yes   | yes¹    | yes¹ | yes¹
EpollEventDriver  | yes   | no      | no   | no
IOCPEventDriver   | no    | yes¹    | no   | no
KqueueEventDriver | no    | no      | yes¹ | yes¹

¹ planned, but not currenly implemented


Driver development status
-------------------------

Feature          | SelectEventDriver | EpollEventDriver | IOCPEventDriver | KqueueEventDriver
-----------------|-------------------|------------------|-----------------|------------------
TCP Sockets      | yes               | yes              | no              | no               
UDP Sockets      | yes               | yes              | no              | no               
USDS             | yes               | yes              | no              | no               
DNS              | yes               | yes              | no              | no               
Timers           | yes               | yes              | no              | no               
Events           | yes               | yes              | no              | no               
Signals          | yes²              | yes²             | no              | no               
Files            | yes               | yes              | no              | no               
UI Integration   | no                | no               | no              | no               
File watcher     | no                | no               | no              | no               

² Currently only supported on Linux


Open questions
--------------

- Error code reporting
- Adopting existing file descriptors
- Enqueued writes
