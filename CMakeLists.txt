cmake_minimum_required(VERSION 3.21)
project(TaterTube VERSION 1.3.9 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

include(GNUInstallDirs)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick Qml Network Svg Concurrent)
find_package(SDL2 CONFIG REQUIRED) # gamepad input (InputManager)

# libdrm is used on Linux/RPi to save and restore the KMS CRTC state
# around mpv playback so Qt EGLFS can resume cleanly after mpv exits.
if(NOT APPLE)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(Libdrm REQUIRED libdrm)
endif()

if(APPLE)
    enable_language(OBJCXX)
endif()

add_executable(240mp
    src/main.cpp
    src/AppCore.cpp
    src/modules/local_files/LocalFilesBackend.cpp
    src/modules/emby_jellyfin/EmbyJellyfinBackend.cpp
    src/modules/retro/RetroBackend.cpp
    src/modules/youtube_playlist/YouTubePlaylistBackend.cpp
    src/modules/moonlight/MoonlightBackend.cpp
    src/modules/usenet/UsenetBackend.cpp
    src/media/CommercialLibrary.cpp
    src/player/MpvController.cpp
    src/input/InputManager.cpp
    src/api/ControlApiServer.cpp
    $<$<BOOL:${APPLE}>:src/macos_utils.mm>
)

target_link_libraries(240mp PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::Qml
    Qt6::Network
    Qt6::Svg
    Qt6::Concurrent
    SDL2::SDL2
    $<$<NOT:$<BOOL:${APPLE}>>:${Libdrm_LIBRARIES}>
)

if(APPLE)
    target_link_libraries(240mp PRIVATE "-framework AppKit")
endif()

if(NOT APPLE)
    target_include_directories(240mp PRIVATE ${Libdrm_INCLUDE_DIRS})
endif()

target_include_directories(240mp PRIVATE
    src
)

target_compile_definitions(240mp PRIVATE
    TATER_TUBE_VERSION="${PROJECT_VERSION}"
)

# ── macOS bundle metadata ──────────────────────────────────────────────────────
set_target_properties(240mp PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_BUNDLE_NAME "Tater Tube"
    MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.tatertotterson.tatertube"
    MACOSX_BUNDLE_ICON_FILE "assets/images/240-mp"
    INSTALL_RPATH_USE_LINK_PATH TRUE
)

# ── Dev bundle symlink (macOS only, non-CI) ───────────────────────────────────
# Makes double-clicking build/240mp.app work during development by symlinking
# Contents/Resources → repo root so resolveAppRoot() finds the QML files.
# Skipped in CI (ENV{CI} is set by GitHub Actions) because cmake --install
# populates Resources with real files — a symlink in the build tree would be
# captured by any packaging step pointing to a CI path that doesn't exist.
if(APPLE AND NOT DEFINED ENV{CI})
    add_custom_command(TARGET 240mp POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E remove -f
            "$<TARGET_BUNDLE_CONTENT_DIR:240mp>/Resources"
        COMMAND ${CMAKE_COMMAND} -E create_symlink
            "${CMAKE_SOURCE_DIR}"
            "$<TARGET_BUNDLE_CONTENT_DIR:240mp>/Resources"
        COMMENT "Symlinking repo root as bundle Resources (dev build)"
    )
endif()

# ── Install rules ──────────────────────────────────────────────────────────────
if(APPLE)
    install(TARGETS 240mp BUNDLE DESTINATION . COMPONENT Runtime)

    # Use a hardcoded relative path — $<TARGET_BUNDLE_CONTENT_DIR> resolves to
    # the build tree, not the install prefix, inside install() rules.
    install(FILES
        "${CMAKE_SOURCE_DIR}/Main.qml"
        "${CMAKE_SOURCE_DIR}/update-manifest.json"
        DESTINATION "240mp.app/Contents/Resources"
        COMPONENT Runtime)

    install(DIRECTORY
        "${CMAKE_SOURCE_DIR}/views"
        "${CMAKE_SOURCE_DIR}/modules"
        "${CMAKE_SOURCE_DIR}/assets"
        DESTINATION "240mp.app/Contents/Resources"
        COMPONENT Runtime)

    install(DIRECTORY
        "${CMAKE_SOURCE_DIR}/scripts"
        DESTINATION "240mp.app/Contents/Resources"
        USE_SOURCE_PERMISSIONS
        COMPONENT Runtime)

    # macdeployqt is NOT run here — it requires Qt frameworks to be present and
    # is environment-specific. Run it manually in CI after cmake --install.
else()
    install(TARGETS 240mp
        RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
        COMPONENT Runtime)

    install(FILES
        "${CMAKE_SOURCE_DIR}/Main.qml"
        "${CMAKE_SOURCE_DIR}/update-manifest.json"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/240mp"
        COMPONENT Runtime)

    install(DIRECTORY
        "${CMAKE_SOURCE_DIR}/views"
        "${CMAKE_SOURCE_DIR}/modules"
        "${CMAKE_SOURCE_DIR}/assets"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/240mp"
        COMPONENT Runtime)

    install(DIRECTORY
        "${CMAKE_SOURCE_DIR}/scripts"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/240mp"
        USE_SOURCE_PERMISSIONS
        COMPONENT Runtime)
endif()

# ── CPack ──────────────────────────────────────────────────────────────────────
# Releases are Linux arm64 tarballs for Raspberry Pi. macOS builds remain a local
# development smoke-test path and are not packaged by CPack.
if(NOT APPLE)
    set(CPACK_PACKAGE_NAME "Tater Tube")
    set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
    set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Tater Tube Media Player")
    set(CPACK_PACKAGE_VENDOR "Tater Tube")
    set(CPACK_GENERATOR "TGZ")
    set(CPACK_PACKAGING_INSTALL_PREFIX "/usr/local")
    include(CPack)
endif()
