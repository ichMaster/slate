# Slate M0 firmware — quarry, not foundation.
#
# The kept firmware/ tree begins at v1.1 (ARCHITECTURE.md §Stack); this project
# exists to answer v0.1's questions and is then thrown away.

cmake_minimum_required(VERSION 3.16)

# sdkconfig.defaults is committed; sdkconfig.defaults.local is gitignored and
# holds this desk's WiFi credentials. ARCHITECTURE.md §Security permits WiFi
# credentials and the server address in firmware — they are the only secrets
# that may live there — but this repository is public, so the real values stay
# out of it. Later entries win, so the local file overrides the committed one.
#
# It is added only when present: ESP-IDF errors out on a listed file that does
# not exist, which would mean a fresh clone could not build at all.
set(SDKCONFIG_DEFAULTS "sdkconfig.defaults")
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/sdkconfig.defaults.local")
    list(APPEND SDKCONFIG_DEFAULTS "sdkconfig.defaults.local")
endif()

# Ідентичність збірки, вшита в бінарник.
#
# Без неї "чи оновилась прошивка" лишається здогадкою: екран виглядає так само,
# а чи доїхав flash — невідомо. Версія береться з того ж VERSION, що й у сервера,
# короткий SHA каже, з якого дерева зібрано, а суфікс -dirty — що в дереві були
# незакомічені зміни, тобто цей бінарник не відтворити з жодного коміту.
file(READ "${CMAKE_CURRENT_LIST_DIR}/../../VERSION" SLATE_VERSION)
string(STRIP "${SLATE_VERSION}" SLATE_VERSION)

execute_process(
    COMMAND git rev-parse --short HEAD
    WORKING_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}"
    OUTPUT_VARIABLE SLATE_GIT_SHA
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
execute_process(
    COMMAND git status --porcelain
    WORKING_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}"
    OUTPUT_VARIABLE SLATE_GIT_DIRTY
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
if(NOT SLATE_GIT_SHA)
    set(SLATE_GIT_SHA "nogit")
endif()
if(SLATE_GIT_DIRTY)
    set(SLATE_GIT_SHA "${SLATE_GIT_SHA}-dirty")
endif()

string(TIMESTAMP SLATE_BUILT "%Y-%m-%dT%H:%M:%S" UTC)

add_compile_definitions(
    SLATE_VERSION="${SLATE_VERSION}"
    SLATE_GIT_SHA="${SLATE_GIT_SHA}"
    SLATE_BUILT="${SLATE_BUILT}")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(slate_m0)

message(STATUS "Slate M0 ${SLATE_VERSION} (${SLATE_GIT_SHA}) built ${SLATE_BUILT}")
