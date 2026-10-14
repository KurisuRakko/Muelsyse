cmake_minimum_required(VERSION 3.28)

# 该目录由匹配版本的 KWin 构建树通过 add_subdirectory() 引入。
project(selkies-kwin-adapter LANGUAGES CXX)

if (NOT TARGET kwin)
    message(FATAL_ERROR "必须从匹配版本的 KWin 构建树编译适配插件")
endif()

kcoreaddons_add_plugin(selkieskwinadapter
    INSTALL_NAMESPACE "kwin/plugins"
    SOURCES
        src/selkies_kwin_adapter.cpp
        src/selkies_kwin_adapter_protocol.h
)

# 请求解析层的离线单元测试：只依赖 Qt6::Core，可在没有 KWin 会话的机器上构建。
# 默认构建（BUILD_TESTING=OFF）不会引入该目标；需要时用
#   cmake --build <build-dir> --target selkies_cursor_request_test && ctest ...
# 或按 tests/cursor_request_test.cpp 顶部的命令行手工编译。
if (BUILD_TESTING)
    add_executable(selkies_cursor_request_test tests/cursor_request_test.cpp)
    target_link_libraries(selkies_cursor_request_test PRIVATE Qt6::Core)
    target_compile_features(selkies_cursor_request_test PRIVATE cxx_std_20)
    add_test(NAME selkies_cursor_request_test COMMAND selkies_cursor_request_test)
endif()

target_link_libraries(selkieskwinadapter
    PRIVATE
        kwin
        Qt6::Network
)

target_compile_features(selkieskwinadapter PRIVATE cxx_std_20)
