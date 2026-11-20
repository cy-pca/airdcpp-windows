# Classic minizip (zlib's contrib/minizip), the library AirDC++ includes as <minizip/unzip.h> and
# <minizip/zip.h> and finds as `unofficial-minizip`, with the layout and target name of vcpkg's
# minizip port (unofficial::minizip::minizip, bzip2 support on). cvcpkg has minizip-ng, whose
# compatibility layer is off, so build.ps1 builds this from the zlib release that matches
# cvcpkg's zlib and links it statically into AirDC.exe; it is not shipped on its own.
cmake_minimum_required(VERSION 3.21)
project(unofficial-minizip C)

if (NOT ZLIB_SOURCE_DIR)
  message(FATAL_ERROR "ZLIB_SOURCE_DIR must point at an unpacked zlib source tree")
endif ()
set(src "${ZLIB_SOURCE_DIR}/contrib/minizip")

find_package(ZLIB REQUIRED)
find_package(BZip2 REQUIRED)

add_library(minizip STATIC
  "${src}/ioapi.c"
  "${src}/unzip.c"
  "${src}/zip.c"
  "${src}/mztools.c"
  "$<$<PLATFORM_ID:Windows>:${src}/iowin32.c>"
)
target_compile_definitions(minizip PRIVATE HAVE_BZIP2 _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE)
target_include_directories(minizip
  PRIVATE "${src}"
  INTERFACE "$<INSTALL_INTERFACE:include>")
target_link_libraries(minizip PRIVATE ZLIB::ZLIB BZip2::BZip2)

install(TARGETS minizip EXPORT unofficial-minizip-targets ARCHIVE DESTINATION lib)
install(FILES
    "${src}/ioapi.h" "${src}/unzip.h" "${src}/zip.h" "${src}/mztools.h" "${src}/iowin32.h"
    "${src}/crypt.h"
  DESTINATION include/minizip)
install(EXPORT unofficial-minizip-targets
  NAMESPACE unofficial::minizip::
  DESTINATION share/unofficial-minizip)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/unofficial-minizipConfig.cmake" [=[
include(CMakeFindDependencyMacro)
find_dependency(ZLIB)
find_dependency(BZip2)
include("${CMAKE_CURRENT_LIST_DIR}/unofficial-minizip-targets.cmake")
]=])
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/unofficial-minizipConfig.cmake"
  DESTINATION share/unofficial-minizip)
