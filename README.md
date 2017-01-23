EventCore
=========

This is a high-performance native event loop abstraction for D, focused on asynchronous I/O and GUI message integration. The API is callback (delegate) based. For a higher level fiber based abstraction, take a look at [vibe.d](https://vibed.org/).

[![DUB Package](https://img.shields.io/dub/v/eventcore.svg)](https://code.dlang.org/packages/eventcore)
[![Posix Build Status](https://travis-ci.org/vibe-d/eventcore.svg?branch=master)](https://travis-ci.org/vibe-d/eventcore)
[![Windows Build Status](https://ci.appveyor.com/api/projects/status/1a9r8sypyy9fq2j8/branch/master?svg=true)](https://ci.appveyor.com/project/s-ludwig/eventcore)


Supported drivers and operating systems
---------------------------------------

Driver               | Linux   | Windows | macOS   | FreeBSD | Android | iOS
---------------------|---------|---------|---------|---------|---------|---------
SelectEventDriver    | yes     | yes     | yes¹    | yes¹    | &mdash; | &mdash;
EpollEventDriver     | yes     | &mdash; | &mdash; | &mdash; | &mdash; | &mdash;
WinAPIEventDriver    | &mdash; | yes     | &mdash; | &mdash; | &mdash; | &mdash;
KqueueEventDriver    | &mdash; | &mdash; | yes¹    | yes¹    | &mdash; | &mdash;
LibasyncEventDriver  | &mdash;¹| &mdash;¹| &mdash;¹| &mdash;¹| &mdash; | &mdash;

¹ planned, but not currenly implemented


Driver development status
-------------------------

Feature          | SelectEventDriver | EpollEventDriver | WinAPIEventDriver | KqueueEventDriver
-----------------|-------------------|------------------|-------------------|------------------
TCP Sockets      | yes               | yes              | &mdash;           | yes              
UDP Sockets      | yes               | yes              | &mdash;           | yes              
USDS             | yes               | yes              | &mdash;           | yes              
DNS              | yes               | yes              | &mdash;           | yes              
Timers           | yes               | yes              | yes               | yes              
Events           | yes               | yes              | yes               | yes              
Unix Signals     | yes²              | yes²             | &mdash;           | &mdash;          
Files            | yes               | yes              | yes               | yes              
UI Integration   | yes¹              | yes¹             | yes               | yes¹             
File watcher     | yes²              | yes²             | yes               | &mdash;          

Feature          | LibasyncEventDriver 
-----------------|---------------------
TCP Sockets      | &mdash;             
UDP Sockets      | &mdash;             
USDS             | &mdash;             
DNS              | &mdash;             
Timers           | &mdash;             
Events           | &mdash;             
Unix Signals     | &mdash;             
Files            | &mdash;             
UI Integration   | &mdash;             
File watcher     | &mdash;             

¹ Manually, by adopting the X11 display connection socket

² Currently only supported on Linux


### Open questions

- Error code reporting
- Adopting existing file descriptors (done for files)
- Enqueued writes
- Use the type system to prohibit passing thread-local handles to foreign threads
