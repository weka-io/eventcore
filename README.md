EventCore
=========

This is a high-performance native event loop abstraction for D, focused on asynchronous I/O and GUI message integration. The API is callback (delegate) based. For a higher level fiber based abstraction, take a look at [vibe.d](https://vibed.org/).


Supported drivers and operating systems
---------------------------------------

                  | Linux | Windows | OS X | FreeBSD
------------------|-------|---------|------|--------
SelectEventDriver | yes   | yes     | yes  | yes    
EpollEventDriver  | yes   | no      | no   | no     
IOCPEventDriver   | no    | yes     | no   | no     
KqueueEventDriver | no    | no      | yes  |        


Driver development status
-------------------------

                 | SelectEventDriver | EpollEventDriver | IOCPEventDriver | KqueueEventDriver
-----------------|-------------------|------------------|-----------------|------------------
TCP Sockets      | yes               | yes              | no              | no               
UDP Sockets      | no                | no               | no              | no               
USDS             | no                | no               | no              | no               
DNS              | no                | no               | no              | no               
Timers           | yes               | yes              | no              | no               
Events           | no                | no               | no              | no               
Signals          | no                | no               | no              | no               
Files            | no                | no               | no              | no               
UI Integration   | no                | no               | no              | no               
File watcher     | no                | no               | no              | no               
