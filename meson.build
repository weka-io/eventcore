project('eventcore', 'd',
    meson_version: '>=0.56',
    version: '0.9.10',
    default_options: ['buildtype=release']
)

project_soversion      = '0'
project_version_suffix = ''
project_version        = meson.project_version()
project_version_full   = project_version + project_version_suffix

taggedalgebraic_dep = dependency('taggedalgebraic', version: ['>=0.10.12', '<0.12'])

source_root = meson.current_source_dir()
build_root = meson.current_build_dir()
subdir('source/eventcore')
