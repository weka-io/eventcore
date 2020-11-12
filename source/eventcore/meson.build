eventcore_src = files(
	'core.d',
	'driver.d',
	'socket.d',
	'drivers/timer.d',
	'drivers/libasync.d',
	'drivers/threadedfile.d',
	'drivers/posix/events.d',
	'drivers/posix/processes.d',
	'drivers/posix/sockets.d',
	'drivers/posix/pipes.d',
	'drivers/posix/select.d',
	'drivers/posix/epoll.d',
	'drivers/posix/dns.d',
	'drivers/posix/driver.d',
	'drivers/posix/signals.d',
	'drivers/posix/kqueue.d',
	'drivers/posix/watchers.d',
	'drivers/posix/cfrunloop.d',
	'drivers/winapi/events.d',
	'drivers/winapi/processes.d',
	'drivers/winapi/sockets.d',
	'drivers/winapi/files.d',
	'drivers/winapi/pipes.d',
	'drivers/winapi/core.d',
	'drivers/winapi/dns.d',
	'drivers/winapi/driver.d',
	'drivers/winapi/signals.d',
	'drivers/winapi/watchers.d',
	'internal/consumablequeue.d',
	'internal/coreservices.d',
	'internal/corefoundation.d',
	'internal/dlist.d',
	'internal/ioworker.d',
	'internal/win32.d',
	'internal/utils.d',
)

eventcore_lib = library(
	'eventcore',
	eventcore_src,
	version: project_version,
	install: true,
	pic: true,
	include_directories: include_directories('../'),
	dependencies: taggedalgebraic_dep,
	d_module_versions: ['EventcoreEpollDriver'],
)

pkgc = import('pkgconfig')

pkgc.generate(
	eventcore_lib,
	subdirs: 'd/eventcore',
	d_module_versions: ['EventcoreEpollDriver'],
	libraries_private: taggedalgebraic_dep,
)

install_subdir('.',
	exclude_files: ['meson.build'],
	install_dir: 'include/d/eventcore/eventcore')

test_exe = executable(
	'eventcore_test',
	eventcore_src,
	include_directories: include_directories('../'),
	dependencies: taggedalgebraic_dep,
	d_module_versions: ['EventcoreEpollDriver'],
	d_unittest: true,
	link_args: '--main',
)
test('test_eventcore', test_exe)
