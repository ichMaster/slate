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
set(SDKCONFIG_DEFAULTS "sdkconfig.defaults;sdkconfig.defaults.local")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(slate_m0)
