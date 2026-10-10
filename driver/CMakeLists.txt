cmake_minimum_required(VERSION 3.12.0)

project(TabletAudio CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CODESIGN_ID "-" CACHE STRING "Codesign identity")

set(DRIVER_NAME "TabletAudio")
set(DRIVER_VERSION "1.0.0")
set(DRIVER_COPYRIGHT "Copyright (c) floweredao")
set(DRIVER_IDENTIFIER "com.floweredao.usbaudiobridge.tabletaudio")
set(DRIVER_UID "6F1A2C3B-8E47-4D5A-9B61-2C7E0D4F8A13")
set(DRIVER_ENTRYPOINT "TabletAudioEntryPoint")

# libASPL (MIT), pinned to a release tag and linked statically.
include(ExternalProject)
ExternalProject_Add(libASPL
  GIT_REPOSITORY https://github.com/gavv/libASPL.git
  GIT_TAG v3.1.2
  GIT_SHALLOW ON
  PREFIX ${CMAKE_CURRENT_BINARY_DIR}/libASPL
  INSTALL_DIR ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix
  CMAKE_ARGS
    -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_TESTING=OFF
  BUILD_BYPRODUCTS ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix/lib/libASPL.a
  )

add_library(${DRIVER_NAME} MODULE Driver.cpp)
add_dependencies(${DRIVER_NAME} libASPL)
target_include_directories(${DRIVER_NAME} PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix/include)
target_compile_options(${DRIVER_NAME} PRIVATE -Wall -Wextra -Wno-unused-parameter)
find_library(LIB_CoreFoundation CoreFoundation REQUIRED)
target_link_libraries(${DRIVER_NAME} PRIVATE
  ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix/lib/libASPL.a
  ${LIB_CoreFoundation})

set_target_properties(${DRIVER_NAME} PROPERTIES
  OUTPUT_NAME "${DRIVER_NAME}"
  BUNDLE true
  BUNDLE_EXTENSION "driver"
  PREFIX ""
  SUFFIX ""
  MACOSX_BUNDLE ON
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "${DRIVER_NAME}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${DRIVER_VERSION}"
  MACOSX_BUNDLE_COPYRIGHT "${DRIVER_COPYRIGHT}"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${DRIVER_IDENTIFIER}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${DRIVER_VERSION}"
  )

add_custom_command(TARGET ${DRIVER_NAME} POST_BUILD
  VERBATIM
  COMMAND codesign --force --timestamp=none -s "${CODESIGN_ID}" "${CMAKE_CURRENT_BINARY_DIR}/${DRIVER_NAME}.driver"
  )
