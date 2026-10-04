cmake_minimum_required(VERSION 3.14)
project(ForumPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

# Derive the module name from metadata.json — single source of truth.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json" METADATA_JSON)
string(JSON MODULE_NAME GET ${METADATA_JSON} name)

# Universal UI module: the .rep view contract + the *Backend class.
# REP_FILE runs repc; the generated *Plugin glue is compiled automatically.
logos_module(
    NAME ${MODULE_NAME}
    REP_FILE src/forum_module.rep
    SOURCES
        src/forum_module_backend.h
        src/forum_module_backend.cpp
        src/core/forum_core.h
        src/core/forum_core.cpp
        src/archive/archive_core.h
        src/archive/archive_core.cpp
    INCLUDE_DIRS
        src
        src/core
        src/archive
    # Load-bearing: the builder links plugins with `-undefined dynamic_lookup`
    # on macOS and does NOT forward metadata.json's extra_link_libraries, so
    # without this the plugin links "fine" with sodium/sqlite unresolved and
    # the first KeyPair::generate() calls a null sodium_init (ui-host SIGSEGV).
    LINK_LIBRARIES
        sqlite3
        sodium
)
