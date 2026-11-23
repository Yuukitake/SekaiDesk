cmake_minimum_required(VERSION 3.21)
project(SekaiDesk VERSION 0.3.4 LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# Build on Windows (MinGW-w64 / MSVC) or cross-built on Colab.
# Qt 6.8+ recommended. Qt modules used: Core, Gui, Qml, Quick, Network.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick Network)

qt_add_executable(SekaiDesk WIN32
    src/main.cpp
    src/compat/QsCore.h        src/compat/QsCore.cpp
    src/compat/QsWindow.h      src/compat/QsWindow.cpp
    src/compat/QsIo.h          src/compat/QsIo.cpp
    src/core/SettingsStore.h   src/core/SettingsStore.cpp
    src/services/WinIconProvider.h src/services/WinIconProvider.cpp
    src/services/AppLauncher.h     src/services/AppLauncher.cpp
    src/services/WindowTracker.h   src/services/WindowTracker.cpp
    src/services/DwmThumbnailItem.h src/services/DwmThumbnailItem.cpp
    src/services/TrashService.h    src/services/TrashService.cpp
    src/services/MediaService.h    src/services/MediaService.cpp
    src/services/AudioService.h    src/services/AudioService.cpp
    src/services/SystemControlService.h src/services/SystemControlService.cpp
    src/services/TrayService.h     src/services/TrayService.cpp
    src/services/ClipboardService.h src/services/ClipboardService.cpp
    src/services/DeskExtrasService.h src/services/DeskExtrasService.cpp
    src/services/NotificationService.h src/services/NotificationService.cpp
    src/services/VisualizerService.h src/services/VisualizerService.cpp
    src/services/WallpaperService.h src/services/WallpaperService.cpp
    src/services/TaskbarManager.h   src/services/TaskbarManager.cpp
    src/services/GameModeService.h  src/services/GameModeService.cpp
    src/services/UpdateService.h    src/services/UpdateService.cpp
    src/services/RamCleanerService.h src/services/RamCleanerService.cpp
    src/SekaiDesk.rc
)

target_include_directories(SekaiDesk PRIVATE src)
target_compile_definitions(SekaiDesk PRIVATE SEKAIDESK_VERSION="${PROJECT_VERSION}")

# Smoke-test shell (Phase 0). Later phases swap this for the full SekaiPop shell.
qt_add_resources(SekaiDesk "qml"
    PREFIX "/"
    FILES
        qml/Shell.qml
        qml/ThemeHub.qml
        qml/ScreenRound.qml
        qml/SettingsModal.qml
        qml/PowerTools.qml
        qml/DesktopWidgets.qml
        qml/DesktopImageWidgets.qml
        qml/VisualizerOverlay.qml
        qml/ShaderVisualizerEngine.qml
        qml/ShaderVisualizerLayer.qml
        qml/TideVisualizer.qml
        qml/ScopeMath.js
        qml/PillVisualizer.qml
        qml/BarExtraPopups.qml
        qml/DockExtraCards.qml
        qml/WallpaperTransitionOverlay.qml
        qml/PhoneWallpaperGallery.qml
        qml/SekaiOsd.qml
        qml/WallpaperSelector.qml
        qml/LauncherPhone2D.qml
        qml/DropShelfBookshelf.qml
        qml/SekaiWashiTape.qml
        qml/SekaiDotField.qml
        qml/SekaiSlant.qml
        qml/SekaiHubTile.qml
        qml/ShelfMath.js
        qml/shaders/visualizer/aurora.frag.qsb
        qml/shaders/visualizer/dots.frag.qsb
        qml/shaders/visualizer/mirror.frag.qsb
        qml/shaders/visualizer/pulse.frag.qsb
        qml/shaders/visualizer/ribbons.frag.qsb
        qml/shaders/visualizer/ring.frag.qsb
        qml/shaders/visualizer/scope.frag.qsb
        qml/shaders/visualizer/tide.frag.qsb
        qml/shaders/wallpaper/fade.vert.qsb
        qml/shaders/wallpaper/fade.frag.qsb
        qml/shaders/wallpaper/sekai_blocks.vert.qsb
        qml/shaders/wallpaper/sekai_blocks.frag.qsb
        qml/shaders/wallpaper/sekai_flash.vert.qsb
        qml/shaders/wallpaper/sekai_flash.frag.qsb
        qml/shaders/wallpaper/sekai_iris.vert.qsb
        qml/shaders/wallpaper/sekai_iris.frag.qsb
        qml/shaders/wallpaper/sekai_ring.vert.qsb
        qml/shaders/wallpaper/sekai_ring.frag.qsb
        qml/shaders/wallpaper/sekai_star.vert.qsb
        qml/shaders/wallpaper/sekai_star.frag.qsb
        qml/assets/phone-shadow.png
        qml/assets/lcd-mesh.png
        qml/assets/lock-dots.png
        qml/icons/alt-arrow-down-dark.svg
        qml/icons/alt-arrow-down-light.svg
        qml/icons/alt-arrow-up-dark.svg
        qml/icons/alt-arrow-up-light.svg
        qml/icons/arrow-down-dark.svg
        qml/icons/arrow-up-dark.svg
        qml/icons/author-pfp.png
        qml/icons/bell-dark.svg
        qml/icons/bell-light.svg
        qml/icons/bt-dark.svg
        qml/icons/bt-light.svg
        qml/icons/calendar-light.svg
        qml/icons/check-circle-dark.svg
        qml/icons/checklist-dark.svg
        qml/icons/clipboard-text-dark.svg
        qml/icons/clipboard-text-light.svg
        qml/icons/clock-circle-dark.svg
        qml/icons/clock-circle-light.svg
        qml/icons/close-circle-dark.svg
        qml/icons/cloud-dark.svg
        qml/icons/cloud-rain-dark.svg
        qml/icons/cloud-snowfall-dark.svg
        qml/icons/cloud-storm-dark.svg
        qml/icons/cloud-sun-dark.svg
        qml/icons/cloudy-moon-dark.svg
        qml/icons/copy-dark.svg
        qml/icons/fog-dark.svg
        qml/icons/folder-with-files-dark.svg
        qml/icons/folder-with-files-light.svg
        qml/icons/handsig-yozora.png
        qml/icons/headphones-round-dark.svg
        qml/icons/inbox-archive-dark.svg
        qml/icons/inbox-archive-light.svg
        qml/icons/magnifer-dark.svg
        qml/icons/magnifer-light.svg
        qml/icons/map-point-teal.svg
        qml/icons/moon-dark.svg
        qml/icons/moon-light.svg
        qml/icons/music-note-dark.svg
        qml/icons/music-note-light.svg
        qml/icons/music-note-teal.svg
        qml/icons/network-dark.svg
        qml/icons/network-light.svg
        qml/icons/notes-dark.svg
        qml/icons/palette-dark.svg
        qml/icons/palette-light.svg
        qml/icons/pause-dark.svg
        qml/icons/pause-light.svg
        qml/icons/pen-dark.svg
        qml/icons/pen-light.svg
        qml/icons/pin-dark.svg
        qml/icons/pin-outline-dark.svg
        qml/icons/pin-outline-light.svg
        qml/icons/play-dark.svg
        qml/icons/play-light.svg
        qml/icons/refresh-light.svg
        qml/icons/sekai-app-icon.png
        qml/icons/settings-dark.svg
        qml/icons/settings-light.svg
        qml/icons/skip-next-dark.svg
        qml/icons/skip-next-light.svg
        qml/icons/skip-previous-dark.svg
        qml/icons/skip-previous-light.svg
        qml/icons/sun-dark.svg
        qml/icons/sun-light.svg
        qml/icons/trash-bin-trash-dark.svg
        qml/icons/trash-bin-trash-light.svg
        qml/icons/trash-bin-trash-red.svg
        qml/icons/user-rounded-dark.svg
        qml/icons/volume-cross-dark.svg
        qml/icons/volume-cross-light.svg
        qml/icons/volume-loud-dark.svg
        qml/icons/volume-loud-light.svg
        qml/icons/waterdrop-dark.svg
        qml/icons/wifi-dark.svg
        qml/icons/wifi-light.svg
        qml/icons/wind-dark.svg
        qml/icons/wonderhoy.png
        qml/icons/archive-dark.svg
        qml/icons/arrow-down-light.svg
        qml/icons/arrow-up-light.svg
        qml/icons/calculator-dark.svg
        qml/icons/camera-dark.svg
        qml/icons/check-read-dark.svg
        qml/icons/clapperboard-play-dark.svg
        qml/icons/clipboard-add-dark.svg
        qml/icons/code-file-dark.svg
        qml/icons/document-text-dark.svg
        qml/icons/folder-2-dark.svg
        qml/icons/folder-open-dark.svg
        qml/icons/gallery-dark.svg
        qml/icons/global-dark.svg
        qml/icons/lock-dark.svg
        qml/icons/logout-dark.svg
        qml/icons/monitor-dark.svg
        qml/icons/moon-sleep-dark.svg
        qml/icons/power-dark.svg
        qml/icons/command-dark.svg
        qml/icons/restart-dark.svg
        qml/icons/rocket-dark.svg
        qml/icons/smartphone-dark.svg
        qml/icons/snowflake-dark.svg
)

target_link_libraries(SekaiDesk PRIVATE
    Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network
)

if(WIN32)
    add_library(SekaiTrayHook SHARED
        src/trayhook/SekaiTrayHook.c
        src/trayhook/TrayHookProtocol.h
    )
    set_target_properties(SekaiTrayHook PROPERTIES
        PREFIX ""
        OUTPUT_NAME "SekaiTrayHook"
    )
    target_include_directories(SekaiTrayHook PRIVATE src)
    target_link_libraries(SekaiTrayHook PRIVATE user32 gdi32 kernel32)
    if(MINGW)
        target_link_options(SekaiTrayHook PRIVATE -static-libgcc)
    endif()
    add_dependencies(SekaiDesk SekaiTrayHook)

    target_link_libraries(SekaiDesk PRIVATE
        dwmapi user32 gdi32 shell32 ole32 oleaut32 ws2_32 winhttp iphlpapi psapi
    )
endif()

install(TARGETS SekaiDesk RUNTIME DESTINATION .)
if(WIN32)
    install(TARGETS SekaiTrayHook RUNTIME DESTINATION .)
endif()
