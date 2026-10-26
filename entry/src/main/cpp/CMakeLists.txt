cmake_minimum_required(VERSION 3.5.0)
project(camelhump)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
set(LLAMA_ROOT  ${NATIVE_ROOT}/third_party/llama.cpp)

# ---------------------------------------------------------------------------
# Optimisation guard.
# A Debug build silently runs at -O0 and makes a 1.5B model look 10x slower than
# it is. This has been misdiagnosed as "the phone cannot run an LLM" more than
# once, so release flags are forced here rather than left to the IDE.
#
# hvigor defaults to buildMode=debug, which reaches CMake as
# CMAKE_BUILD_TYPE=Debug and therefore -O0 for every translation unit --
# including all of llama.cpp. A matrix multiply compiled at -O0 loses the NEON
# intrinsics' benefit almost entirely, so the guard below rewrites the Debug
# flags as well instead of only topping up Release.
# ---------------------------------------------------------------------------
option(CAMELHUMP_OPTIMIZE_IN_DEBUG
       "Compile at -O3 even when the build type is Debug (recommended)" ON)

if(CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
  add_compile_options(-O3 -DNDEBUG -fvectorize -ffp-contract=fast)
  add_compile_options(-fno-finite-math-only -fvisibility=hidden)
elseif(CAMELHUMP_OPTIMIZE_IN_DEBUG)
  message(STATUS "CamelHump: build type is '${CMAKE_BUILD_TYPE}', overriding -O0 with -O3")
  set(CMAKE_C_FLAGS_DEBUG   "-O3 -g" CACHE STRING "" FORCE)
  set(CMAKE_CXX_FLAGS_DEBUG "-O3 -g" CACHE STRING "" FORCE)
  add_compile_options(-DNDEBUG -fvectorize -ffp-contract=fast)
  add_compile_options(-fno-finite-math-only)
endif()

add_library(camelhump SHARED
    napi_init.cpp
    gguf_inspector.cpp
    llama_bridge.cpp)

target_include_directories(camelhump PRIVATE ${NATIVE_ROOT})

# libace_napi.z.so / libhilog_ndk.z.so are runtime-provided system libraries.
# The trailing .z must be present or packaging fails with "library not found".
target_link_libraries(camelhump PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so)

# ---------------------------------------------------------------------------
# llama.cpp — optional at configure time so the project still builds (UI-only,
# engine reported as stub) before the submodule is fetched.
# ---------------------------------------------------------------------------
if(EXISTS ${LLAMA_ROOT}/CMakeLists.txt)
  set(LLAMA_BUILD_TESTS    OFF CACHE BOOL   "" FORCE)
  set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL   "" FORCE)
  set(LLAMA_BUILD_SERVER   OFF CACHE BOOL   "" FORCE)
  set(LLAMA_CURL           OFF CACHE BOOL   "" FORCE)
  set(BUILD_SHARED_LIBS    OFF CACHE BOOL   "" FORCE)
  set(GGML_BACKEND_DL      OFF CACHE BOOL   "" FORCE)
  set(GGML_OPENMP          OFF CACHE BOOL   "" FORCE)
  set(GGML_NATIVE          OFF CACHE BOOL   "" FORCE)
  # -march 只在 GGML_NATIVE=OFF 时才被采用, 两者互斥。
  set(GGML_CPU_ARM_ARCH    "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)
  # KleidiAI 由 FetchContent 在配置期从 GitHub Releases 下载源码。
  # 交叉编译环境经常拉不到, 一旦失败整个构建就停在 configure 阶段,
  # 因此默认关闭, 只用 -march 打开 dotprod/fp16 这两组最关键的 NEON 指令。
  set(GGML_CPU_KLEIDIAI    OFF CACHE BOOL   "" FORCE)
  # LTO 在 NDK 交叉链接下会明显拉长链接时间, 且对这个体积的目标收益有限。
  set(GGML_LTO             OFF CACHE BOOL   "" FORCE)

  message(STATUS "CamelHump: building with llama.cpp at ${LLAMA_ROOT}")
  add_subdirectory(${LLAMA_ROOT} ${CMAKE_BINARY_DIR}/llama.cpp)

  # ggml-cpu.c uses CPU_ZERO / CPU_SET, which OHOS's musl only exposes when
  # _GNU_SOURCE is set (same as glibc). Without it the file fails to compile
  # with "use of undeclared identifier 'cpuset'".
  target_compile_definitions(ggml-cpu PRIVATE _GNU_SOURCE)

  target_compile_definitions(camelhump PRIVATE CAMELHUMP_WITH_LLAMA=1)
  target_link_libraries(camelhump PUBLIC llama ggml)

  # Newer llama.cpp renamed the KV API (llama_kv_cache_clear -> llama_memory_clear).
  # If you pin an older revision, configure with -DCAMELHUMP_LEGACY_KV_API=ON.
  option(CAMELHUMP_LEGACY_KV_API "Use the pre-2025 llama.cpp KV cache API" OFF)
  if(CAMELHUMP_LEGACY_KV_API)
    target_compile_definitions(camelhump PRIVATE CAMELHUMP_LEGACY_KV_API=1)
  endif()
else()
  message(WARNING
    "CamelHump: llama.cpp not found at ${LLAMA_ROOT}.\n"
    "  The app will build and run, but every load attempt reports 'engine not compiled in'.\n"
    "  Fix: git submodule update --init --recursive")
endif()
