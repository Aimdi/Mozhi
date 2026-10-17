# Writes Marian's common/git_revision.h without git (see ../CMakeLists.txt).
# Usage: cmake -DOUTPUT=<file> -DREVISION=<text> -P write_git_revision.cmake
set(_content "#define GIT_REVISION \"${REVISION}\"\n")
if(EXISTS "${OUTPUT}")
  file(READ "${OUTPUT}" _current)
  if(_current STREQUAL _content)
    return()
  endif()
endif()
file(WRITE "${OUTPUT}" "${_content}")
