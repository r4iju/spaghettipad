#!/usr/bin/env python3
"""Stage the pinned sources for tvOS without dirtying the maintained gitlinks."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
out = Path(sys.argv[1]).resolve()
if out != root / "build-tvos-source":
    raise SystemExit("tvOS staging must use this checkout’s build-tvos-source directory")
subprocess.run([sys.executable, str(root / 'scripts/check-source-pins.py')], check=True)
for relative in ('', 'libultraship', 'torch'):
    destination = out / relative
    destination.mkdir(parents=True, exist_ok=True)
    archive = subprocess.Popen(['git', '-C', str(root / 'sources/spaghettikart' / relative), 'archive', 'HEAD'], stdout=subprocess.PIPE)
    subprocess.run(['tar', '-xf', '-', '-C', str(destination)], stdin=archive.stdout, check=True)
    archive.stdout.close()
    if archive.wait():
        raise SystemExit('Source archive failed')

def replace(path, old, new):
    p = out / path
    text = p.read_text()
    if old not in text:
        raise SystemExit(f'Source contract changed: {path}: {old}')
    p.write_text(text.replace(old, new))

for p in out.rglob('CMakeLists.txt'):
    if 'torch/lib' in str(p):
        continue
    p.write_text(p.read_text().replace('STREQUAL "iOS"', 'MATCHES "^(iOS|tvOS)$"'))
replace('cmake/dependencies/FindLib.cmake', 'STREQUAL "iOS"', 'MATCHES "^(iOS|tvOS)$"')
# CMake already supplies a tvOS SDK, so do not run the late iOS toolchain hook.
replace('libultraship/CMakeLists.txt', 'if(CMAKE_SYSTEM_NAME MATCHES "^(iOS|tvOS)$")\n    include(cmake/ios-toolchain-populate.cmake)', 'if(CMAKE_SYSTEM_NAME STREQUAL "iOS")\n    include(cmake/ios-toolchain-populate.cmake)')
replace('CMakeLists.txt', 'SpaghettiPadShell.mm', 'SpaghettiTVShell.mm')
replace('CMakeLists.txt', '    "${SPAGHETTIPAD_SHELL_DIR}/Assets.xcassets"\n', '')
replace('CMakeLists.txt', 'PRIVATE PLATFORM_IOS=1 __IOS__ MA_NO_DEVICE_IO', 'PRIVATE PLATFORM_IOS=1 __IOS__ __TVOS__ MA_NO_DEVICE_IO')
replace('CMakeLists.txt', 'XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"', 'XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "3"')
replace('CMakeLists.txt', 'XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"', 'XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME ""')
replace('CMakeLists.txt', 'target_link_libraries(${PROJECT_NAME} PRIVATE "-framework CoreMotion")', 'target_link_libraries(${PROJECT_NAME} PRIVATE "-framework GameController")')
replace('libultraship/src/CMakeLists.txt', '        __IOS__\n', '        __IOS__ __TVOS__\n')
replace('libultraship/src/ship/Context.cpp', '#ifdef __IOS__\n    const char* home = getenv("HOME");', '#ifdef __TVOS__\n    const char* home = getenv("HOME");\n    return std::string(home) + "/Library/Caches/SpaghettiPad";\n#elif defined(__IOS__)\n    const char* home = getenv("HOME");')
replace('src/port/Game.cpp', '    // load_wasm();', '#ifdef __TVOS__\n    extern void SpaghettiTV_PrepareGameData();\n    SpaghettiTV_PrepareGameData();\n#endif\n    // load_wasm();')
# Persist the 512-byte EEPROM immediately, even if tvOS later purges caches.
replace('libultraship/src/libultraship/libultra/os_eeprom.cpp', '    fclose(fp);\n    return ret;\n}', '    fclose(fp);\n#ifdef __TVOS__\n    if (ret == 0) { extern void SpaghettiTV_PersistSave(); SpaghettiTV_PersistSave(); }\n#endif\n    return ret;\n}')
replace('src/port/ui/PortMenu.cpp', '#ifdef __IOS__\n    AddWidget(path, "Touch Controls"', '#ifdef __TVOS__\n    AddWidget(path, "Transfer game data / save backup", WIDGET_BUTTON)\n        .Callback([](WidgetInfo&) { extern void SpaghettiTV_OpenTransfer(); SpaghettiTV_OpenTransfer(); });\n#endif\n#if defined(__IOS__) && !defined(__TVOS__)\n    AddWidget(path, "Touch Controls"')
replace('src/port/ui/PortMenu.cpp', '#include "SpaghettiPadTouchControls.h"', '#include "SpaghettiPadTouchControls.h"\n#ifdef __TVOS__\nvoid SpaghettiTV_OpenTransfer();\n#endif')
replace('src/port/ui/PortMenu.cpp', 'extern void SpaghettiTV_OpenTransfer(); SpaghettiTV_OpenTransfer();', 'SpaghettiTV_OpenTransfer();')
replace('CMakeLists.txt', 'target_link_libraries(${PROJECT_NAME} PRIVATE "-framework GameController")', 'target_link_libraries(${PROJECT_NAME} PRIVATE "-framework GameController" libzip::zip)')
replace('libultraship/src/ship/controller/physicaldevice/ConnectedPhysicalDeviceManager.cpp', '#if TARGET_OS_SIMULATOR\n        const char* simulatorControllerName', '#ifdef __TVOS__\n        const char* tvControllerName = SDL_GameControllerNameForIndex(i);\n        if (tvControllerName != nullptr && SDL_strcmp(tvControllerName, "Remote") == 0) {\n            if (!isPeriodicCheck) SPDLOG_DEBUG("Keeping the Apple TV Remote out of racing slots");\n            continue;\n        }\n#endif\n#if TARGET_OS_SIMULATOR\n        const char* simulatorControllerName')
print(out)

# Local branding is optional and remains outside the staged source archives.
p = out / 'CMakeLists.txt'
with p.open('a') as cmake:
    cmake.write('\nif(EXISTS "${SPAGHETTIPAD_SHELL_DIR}/LocalBranding.xcassets")\n  target_sources(${PROJECT_NAME} PRIVATE "${SPAGHETTIPAD_SHELL_DIR}/LocalBranding.xcassets")\n  set_source_files_properties("${SPAGHETTIPAD_SHELL_DIR}/LocalBranding.xcassets" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)\n  set_target_properties(${PROJECT_NAME} PROPERTIES XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon")\nendif()\n')
