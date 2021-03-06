include(FindPackageHandleStandardArgs)

set(LUAJIT_VERSION_MAJOR 2)
set(LUAJIT_VERSION_MINOR 0)
set(LUAJIT_VERSION_BASE ${LUAJIT_VERSION_MAJOR}.${LUAJIT_VERSION_MINOR})
set(LUAJIT_VERSION_EXTRA .5)
set(LUAJIT_BASENAME "LuaJIT-${LUAJIT_VERSION_BASE}${LUAJIT_VERSION_EXTRA}")
set(LUAJIT_URL "https://luajit.org/download/${LUAJIT_BASENAME}.tar.gz")
set(LUAJIT_TAR "${PROJECT_BINARY_DIR}/${LUAJIT_BASENAME}.tar.gz")
set(LUAJIT_SOURCE_DIR "${PROJECT_BINARY_DIR}/${LUAJIT_BASENAME}")
set(LUAJIT_INSTALL_PREFIX "${PROJECT_BINARY_DIR}/luajit")
set(LUAJIT_INCLUDE_DIR "${LUAJIT_INSTALL_PREFIX}/include/luajit-${LUAJIT_VERSION_BASE}")
set(LUAJIT_HEADER_BASENAMES lua.h lualib.h lauxlib.h luaconf.h)
set(LUAJIT_LIBRARY_NAME_WE "${LUAJIT_INSTALL_PREFIX}/lib/libluajit-5.1")
set(LUAJIT_EXECUTABLE "${LUAJIT_INSTALL_PREFIX}/bin/luajit-${LUAJIT_VERSION_BASE}${LUAJIT_VERSION_EXTRA}")

string(CONCAT
  LUAJIT_STATIC_LIBRARY
  "${LUAJIT_LIBRARY_NAME_WE}"
  "${CMAKE_STATIC_LIBRARY_SUFFIX}"
)

string(CONCAT
  LUAJIT_SHARED_LIBRARY
  "${LUAJIT_LIBRARY_NAME_WE}"
  "${CMAKE_SHARED_LIBRARY_SUFFIX}"
)

file(DOWNLOAD "${LUAJIT_URL}" "${LUAJIT_TAR}")

add_custom_command(
  OUTPUT ${LUAJIT_SOURCE_DIR}
  DEPENDS ${LUAJIT_TAR}
  COMMAND "${CMAKE_COMMAND}" -E tar xzf "${LUAJIT_TAR}"
  WORKING_DIRECTORY ${PROJECT_BINARY_DIR}
  VERBATIM
)

foreach(LUAJIT_HEADER ${LUAJIT_HEADER_BASENAMES})
  list(APPEND LUAJIT_INSTALL_HEADERS "${LUAJIT_INCLUDE_DIR}/${LUAJIT_HEADER}")
endforeach()

list(APPEND LUAJIT_SHARED_LIBRARY_PATHS
  "${LUAJIT_SHARED_LIBRARY}"
)
if(UNIX AND NOT APPLE)
  list(APPEND LUAJIT_SHARED_LIBRARY_PATHS
    "${LUAJIT_SHARED_LIBRARY}.${LUAJIT_VERSION_MAJOR}"
    "${LUAJIT_SHARED_LIBRARY}.${LUAJIT_VERSION_BASE}${LUAJIT_VERSION_EXTRA}"
  )
endif()

add_custom_command(
  OUTPUT ${LUAJIT_STATIC_LIBRARY} ${LUAJIT_SHARED_LIBRARY_PATHS} ${LUAJIT_EXECUTABLE} ${LUAJIT_INSTALL_HEADERS}
  DEPENDS ${LUAJIT_SOURCE_DIR}
  COMMAND make install "PREFIX=${LUAJIT_INSTALL_PREFIX}" "CC=${CMAKE_C_COMPILER}" "STATIC_CC=${CMAKE_C_COMPILER} -fPIC"
  WORKING_DIRECTORY ${LUAJIT_SOURCE_DIR}
  VERBATIM
)

foreach(LUAJIT_HEADER ${LUAJIT_HEADER_BASENAMES})
  list(APPEND LUAJIT_HEADERS ${PROJECT_BINARY_DIR}/include/terra/${LUAJIT_HEADER})
endforeach()

foreach(LUAJIT_HEADER ${LUAJIT_HEADER_BASENAMES})
  add_custom_command(
    OUTPUT ${PROJECT_BINARY_DIR}/include/terra/${LUAJIT_HEADER}
    DEPENDS
      ${LUAJIT_INCLUDE_DIR}/${LUAJIT_HEADER}
    COMMAND "${CMAKE_COMMAND}" -E copy "${LUAJIT_INCLUDE_DIR}/${LUAJIT_HEADER}" "${PROJECT_BINARY_DIR}/include/terra/"
    VERBATIM
  )
  install(
    FILES ${PROJECT_BINARY_DIR}/include/terra/${LUAJIT_HEADER}
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/terra
  )
endforeach()

if(TERRA_SLIB_INCLUDE_LUAJIT)
  set(LUAJIT_OBJECT_DIR "${PROJECT_BINARY_DIR}/lua_objects")

  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${LUAJIT_OBJECT_DIR}"
  )

  # Since we need the list of objects at configure time, best we can do
  # (without building LuaJIT right this very second) is to guess based
  # on the source files contained in the release tarball.
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar tzf "${LUAJIT_TAR}"
    OUTPUT_VARIABLE LUAJIT_TAR_CONTENTS
  )

  string(REGEX MATCHALL
    "[^/\n]+/src/l[ij][b_][^\n]+[.]c"
    LUAJIT_SOURCES
    ${LUAJIT_TAR_CONTENTS}
  )

  foreach(LUAJIT_SOURCE ${LUAJIT_SOURCES})
    string(REGEX MATCH
      "[^/\n]+[.]c"
      LUAJIT_SOURCE_BASENAME
      ${LUAJIT_SOURCE}
    )
    string(REGEX REPLACE
      [.]c .o
      LUAJIT_OBJECT_BASENAME
      ${LUAJIT_SOURCE_BASENAME}
    )
    list(APPEND LUAJIT_OBJECT_BASENAMES ${LUAJIT_OBJECT_BASENAME})
  endforeach()
  list(APPEND LUAJIT_OBJECT_BASENAMES lj_vm.o)

  foreach(LUAJIT_OBJECT ${LUAJIT_OBJECT_BASENAMES})
    list(APPEND LUAJIT_OBJECTS "${LUAJIT_OBJECT_DIR}/${LUAJIT_OBJECT}")
  endforeach()

  add_custom_command(
    OUTPUT ${LUAJIT_OBJECTS}
    DEPENDS ${LUAJIT_STATIC_LIBRARY}
    COMMAND "${CMAKE_AR}" x "${LUAJIT_STATIC_LIBRARY}"
    WORKING_DIRECTORY ${LUAJIT_OBJECT_DIR}
    VERBATIM
  )

  # Don't link libraries, since we're using the extracted object files.
  list(APPEND LUAJIT_LIBRARIES)
elseif(TERRA_STATIC_LINK_LUAJIT)
  if(APPLE)
    list(APPEND LUAJIT_LIBRARIES "-Wl,-force_load,${LUAJIT_STATIC_LIBRARY}")
  elseif(UNIX)
    list(APPEND LUAJIT_LIBRARIES
      -Wl,-export-dynamic
      -Wl,--whole-archive
      "${LUAJIT_STATIC_LIBRARY}"
      -Wl,--no-whole-archive
    )
  else()
    list(APPEND LUAJIT_LIBRARIES ${LUAJIT_STATIC_LIBRARY})
  endif()

  # Don't extract individual object files.
  list(APPEND LUAJIT_OBJECTS)
else()
  list(APPEND LUAJIT_LIBRARIES ${LUAJIT_SHARED_LIBRARY})

  # Make a copy of the LuaJIT shared library into the local build and
  # install so that all the directory structures are consistent.
  # Note: Need to copy all symlinks (*.so.0 etc.).
  foreach(LUAJIT_SHARED_LIBRARY_PATH ${LUAJIT_SHARED_LIBRARY_PATHS})
    get_filename_component(LUAJIT_SHARED_LIBRARY_NAME "${LUAJIT_SHARED_LIBRARY_PATH}" NAME)
    add_custom_command(
      OUTPUT ${PROJECT_BINARY_DIR}/lib/${LUAJIT_SHARED_LIBRARY_NAME}
      DEPENDS ${LUAJIT_SHARED_LIBRARY_PATH}
      COMMAND "${CMAKE_COMMAND}" -E copy "${LUAJIT_SHARED_LIBRARY_PATH}" "${PROJECT_BINARY_DIR}/lib/${LUAJIT_SHARED_LIBRARY_NAME}"
      VERBATIM
    )
    list(APPEND LUAJIT_SHARED_LIBRARY_BUILD_PATHS
      ${PROJECT_BINARY_DIR}/lib/${LUAJIT_SHARED_LIBRARY_NAME}
    )

    install(
      FILES ${LUAJIT_SHARED_LIBRARY_PATH}
      DESTINATION ${CMAKE_INSTALL_LIBDIR}
    )
  endforeach()

  # Don't extract individual object files.
  list(APPEND LUAJIT_OBJECTS)
endif()

add_custom_target(
  LuaJIT
  DEPENDS
    ${LUAJIT_STATIC_LIBRARY}
    ${LUAJIT_SHARED_LIBRARY_PATHS}
    ${LUAJIT_SHARED_LIBRARY_BUILD_PATHS}
    ${LUAJIT_EXECUTABLE}
    ${LUAJIT_HEADERS}
    ${LUAJIT_OBJECTS}
)

mark_as_advanced(
  LUAJIT_VERSION_BASE
  LUAJIT_VERSION_EXTRA
  LUAJIT_BASENAME
  LUAJIT_URL
  LUAJIT_TAR
  LUAJIT_SOURCE_DIR
  LUAJIT_INCLUDE_DIR
  LUAJIT_HEADER_BASENAMES
  LUAJIT_OBJECT_DIR
  LUAJIT_LIBRARY
  LUAJIT_EXECUTABLE
)
