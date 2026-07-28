cmake_minimum_required(VERSION 3.14)
project(srh_headless CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(RIX ${CMAKE_CURRENT_SOURCE_DIR}/../../external/RasterIX)
set(OBJ_DIR ${RIX}/rtl/top/Verilator/obj_dir) # prebuilt: make -f Makefile.linux rixif
if (NOT DEFINED VERILATOR_INC)
    set(VERILATOR_INC /usr/local/share/verilator/include)
endif()

# RasterIX config: mirrors qtRasterizerFpga sim build (rixif, fixed-point),
# resolution = our spec target 480x272 (D1), LG=15 matches Makefile.linux.
set(RIX_DRIVER_VERILATOR ON CACHE BOOL "" FORCE)
set(RIX_CORE_TMU_COUNT "2" CACHE STRING "" FORCE) # must match top.v build
set(RIX_CORE_MAX_TEXTURE_SIZE "256" CACHE STRING "" FORCE)
set(RIX_CORE_ENABLE_MIPMAPPING "true" CACHE STRING "" FORCE)
set(RIX_CORE_MAX_DISPLAY_WIDTH "480" CACHE STRING "" FORCE)
set(RIX_CORE_MAX_DISPLAY_HEIGHT "272" CACHE STRING "" FORCE)
set(RIX_CORE_FRAMEBUFFER_SIZE_IN_PIXEL_LG "15" CACHE STRING "" FORCE)
set(RIX_CORE_USE_FLOAT_INTERPOLATION "false" CACHE STRING "" FORCE)
# memory map fits the SoC's 16MB SDRAM (was a 32MB layout): GRAM/textures
# 0x0-0x400000, buffers parked in the top 8MB; stream replay in sim/gpu
# reuses these addresses verbatim
set(RIX_CORE_NUMBER_OF_TEXTURE_PAGES "1024" CACHE STRING "" FORCE)
set(RIX_CORE_NUMBER_OF_TEXTURES "1024" CACHE STRING "" FORCE)
set(RIX_CORE_TEXTURE_PAGE_SIZE "4096" CACHE STRING "" FORCE)
set(RIX_CORE_GRAM_MEMORY_LOC "0x0" CACHE STRING "" FORCE)
set(RIX_CORE_COLOR_BUFFER_LOC_0 "0x00E00000" CACHE STRING "" FORCE)
set(RIX_CORE_COLOR_BUFFER_LOC_1 "0x00E00000" CACHE STRING "" FORCE)
set(RIX_CORE_COLOR_BUFFER_LOC_2 "0x00C00000" CACHE STRING "" FORCE)
set(RIX_CORE_DEPTH_BUFFER_LOC "0x00A00000" CACHE STRING "" FORCE)
set(RIX_CORE_STENCIL_BUFFER_LOC "0x00900000" CACHE STRING "" FORCE)
set(RIX_CORE_THREADED_RASTERIZATION "true" CACHE STRING "" FORCE)
set(RIX_CORE_THREADED_RASTERIZATION_DISPLAY_LIST_SIZE "1048576" CACHE STRING "" FORCE)
set(RIX_CORE_ENABLE_VSYNC "false" CACHE STRING "" FORCE)
set(RIX_CORE_MAX_VBO_COUNT "256" CACHE STRING "" FORCE)
set(RIX_CORE_PERFORMANCE_MODE "true" CACHE STRING "" FORCE)
set(RIX_CORE_SOFTWARE_RENDERING "false" CACHE STRING "" FORCE)

add_subdirectory(${RIX} rasterix)

add_executable(headless
    main.cpp
    ${VERILATOR_INC}/verilated.cpp
    ${VERILATOR_INC}/verilated_threads.cpp
)
target_include_directories(headless PRIVATE
    ${OBJ_DIR}
    ${VERILATOR_INC}
    ${VERILATOR_INC}/vltstd
    ${RIX}/lib/driver/verilator
    ${RIX}/example/minimal
    ${RIX}/lib/3rdParty/span/include
    ${RIX}/lib/utils
    ${RIX}/lib/stubs/spdlog
)
option(USE_SPRITE_SCENE "Render the alpha-blended sprite test scene instead of Minimal" ON)
if (USE_SPRITE_SCENE)
    target_compile_definitions(headless PRIVATE USE_SPRITE_SCENE)
endif()

find_package(Threads REQUIRED)
target_link_libraries(headless PRIVATE gl threadrunner ${OBJ_DIR}/Vtop__ALL.a Threads::Threads)