#!/usr/bin/env python3
"""
Generate a bare-bones Xcode project skeleton for ScreenTimeScheduler.

Targets:
  - ScreenTimeScheduler       (iOS 16+)
  - ScreenTimeSchedulerMac    (macOS 13+)
  - DeviceActivityMonitorExtension-iOS
  - DeviceActivityMonitorExtension-macOS
  - ShieldConfigurationExtension-iOS
  - ShieldConfigurationExtension-macOS
  - ShieldActionExtension-iOS
  - ShieldActionExtension-macOS

Shared:
  - Core/   (shared Swift sources, compiled into each app target)
  - App Group: group.com.example.sts
"""

import os, textwrap, uuid, json
from pathlib import Path

ROOT = Path(__file__).parent.parent

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
_used: set[str] = set()

def gid() -> str:
    """Return a 24-character uppercase hex string (Xcode object ID style)."""
    while True:
        v = uuid.uuid4().hex[:24].upper()
        if v not in _used:
            _used.add(v)
            return v

def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(content))
    print(f"  wrote {path.relative_to(ROOT)}")


# ──────────────────────────────────────────────────────────────────────────────
# Source files
# ──────────────────────────────────────────────────────────────────────────────

def write_sources() -> None:
    # iOS app
    write(ROOT / "ScreenTimeScheduler/App/iOS/ScreenTimeSchedulerApp.swift", """\
        import SwiftUI
        import FamilyControls

        @main
        struct ScreenTimeSchedulerApp: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
    """)
    write(ROOT / "ScreenTimeScheduler/App/iOS/ContentView.swift", """\
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("Hello, Screen Time Scheduler (iOS)")
                    .padding()
            }
        }
    """)

    # macOS app
    write(ROOT / "ScreenTimeScheduler/App/macOS/ScreenTimeSchedulerApp.swift", """\
        import SwiftUI
        import FamilyControls

        @main
        struct ScreenTimeSchedulerApp: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
    """)
    write(ROOT / "ScreenTimeScheduler/App/macOS/ContentView.swift", """\
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("Hello, Screen Time Scheduler (macOS)")
                    .padding()
            }
        }
    """)

    # Core placeholder
    write(ROOT / "ScreenTimeScheduler/Core/Placeholder.swift", """\
        // Core shared code goes here.
        // See PLAN.md "Module Layout" for the intended structure:
        //   Models/, Persistence/, Sync/, Scheduling/, Enforcement/, Requests/
        enum Core {}
    """)

    # DeviceActivityMonitor extension
    for platform in ("iOS", "macOS"):
        write(ROOT / f"ScreenTimeScheduler/Extensions/DeviceActivityMonitorExtension/{platform}/DeviceActivityMonitorExtension.swift", f"""\
            import DeviceActivity
            import os

            private let logger = Logger(subsystem: "com.example.sts.DAMExtension", category: "monitor")

            class DeviceActivityMonitorExtension: DeviceActivityMonitor {{
                override func intervalDidStart(for activity: DeviceActivityName) {{
                    logger.info("intervalDidStart: \\(activity.rawValue)")
                }}

                override func intervalDidEnd(for activity: DeviceActivityName) {{
                    logger.info("intervalDidEnd: \\(activity.rawValue)")
                }}

                override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                                     activity: DeviceActivityName) {{
                    logger.info("threshold reached: \\(event.rawValue) activity: \\(activity.rawValue)")
                }}
            }}
        """)

    # ShieldConfiguration extension
    for platform in ("iOS", "macOS"):
        write(ROOT / f"ScreenTimeScheduler/Extensions/ShieldConfigurationExtension/{platform}/ShieldConfigurationExtension.swift", f"""\
            import ManagedSettings
            import ManagedSettingsUI
            import UIKit

            class ShieldConfigurationExtension: ShieldConfigurationDataSource {{
                override func configuration(shielding application: Application) -> ShieldConfiguration {{
                    ShieldConfiguration(
                        backgroundBlurStyle: .systemUltraThinMaterial,
                        title: ShieldConfiguration.Label(text: "App Shielded", color: .label)
                    )
                }}

                override func configuration(shielding application: Application,
                                            in category: ActivityCategory) -> ShieldConfiguration {{
                    configuration(shielding: application)
                }}

                override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {{
                    configuration(shielding: Application())
                }}

                override func configuration(shielding webDomain: WebDomain,
                                            in category: ActivityCategory) -> ShieldConfiguration {{
                    configuration(shielding: Application())
                }}
            }}
        """)

    # ShieldAction extension
    for platform in ("iOS", "macOS"):
        write(ROOT / f"ScreenTimeScheduler/Extensions/ShieldActionExtension/{platform}/ShieldActionExtension.swift", f"""\
            import ManagedSettings
            import os

            private let logger = Logger(subsystem: "com.example.sts.ShieldActionExtension", category: "shield")

            class ShieldActionExtension: ShieldActionDelegate {{
                override func handle(action: ShieldAction,
                                     for application: ApplicationToken,
                                     completionHandler: @escaping (ShieldActionResponse) -> Void) {{
                    logger.info("ShieldAction \\(String(describing: action)) for app token")
                    completionHandler(.close)
                }}

                override func handle(action: ShieldAction,
                                     for webDomain: WebDomainToken,
                                     completionHandler: @escaping (ShieldActionResponse) -> Void) {{
                    completionHandler(.close)
                }}

                override func handle(action: ShieldAction,
                                     for category: ActivityCategoryToken,
                                     completionHandler: @escaping (ShieldActionResponse) -> Void) {{
                    completionHandler(.close)
                }}
            }}
        """)


# ──────────────────────────────────────────────────────────────────────────────
# Entitlements
# ──────────────────────────────────────────────────────────────────────────────

APP_ENTITLEMENTS = """\
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.developer.family-controls</key>
        <true/>
        <key>com.apple.developer.deviceactivity</key>
        <true/>
        <key>com.apple.security.application-groups</key>
        <array>
            <string>group.com.example.sts</string>
        </array>
        <key>com.apple.developer.push-to-talk</key>
        <false/>
        <!-- Background modes set in Info.plist; entitlement not required for remote-notification -->
    </dict>
    </plist>
"""

EXT_ENTITLEMENTS = """\
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.application-groups</key>
        <array>
            <string>group.com.example.sts</string>
        </array>
    </dict>
    </plist>
"""

def write_entitlements() -> None:
    write(ROOT / "ScreenTimeScheduler/App/iOS/ScreenTimeScheduler.entitlements", APP_ENTITLEMENTS)
    write(ROOT / "ScreenTimeScheduler/App/macOS/ScreenTimeSchedulerMac.entitlements", APP_ENTITLEMENTS)
    for ext in ("DeviceActivityMonitorExtension", "ShieldConfigurationExtension", "ShieldActionExtension"):
        for platform in ("iOS", "macOS"):
            write(ROOT / f"ScreenTimeScheduler/Extensions/{ext}/{platform}/{ext}.entitlements",
                  EXT_ENTITLEMENTS)


# ──────────────────────────────────────────────────────────────────────────────
# Info.plist files
# ──────────────────────────────────────────────────────────────────────────────

def info_plist(bundle_id: str, bundle_name: str, extra: str = "") -> str:
    return textwrap.dedent(f"""\
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>{bundle_id}</string>
            <key>CFBundleName</key>
            <string>{bundle_name}</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>CFBundlePackageType</key>
            <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
            <key>LSMinimumSystemVersion</key>
            <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
        {extra}
        </dict>
        </plist>
    """)

def info_plist_ios(bundle_id: str, bundle_name: str, extra: str = "") -> str:
    return textwrap.dedent(f"""\
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>{bundle_id}</string>
            <key>CFBundleName</key>
            <string>{bundle_name}</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>CFBundlePackageType</key>
            <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
            <key>UILaunchScreen</key>
            <dict/>
            <key>UIBackgroundModes</key>
            <array>
                <string>remote-notification</string>
            </array>
        {extra}
        </dict>
        </plist>
    """)

EXT_IOS_EXTRA = """\
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>{point}</string>
    </dict>"""

EXT_MACOS_EXTRA = """\
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>{point}</string>
    </dict>"""

EXT_POINTS = {
    "DeviceActivityMonitorExtension": "com.apple.deviceactivity.monitor-extension",
    "ShieldConfigurationExtension":   "com.apple.ManagedSettings.ShieldConfigurationExtensionPoint",
    "ShieldActionExtension":          "com.apple.ManagedSettings.ShieldActionExtensionPoint",
}

def write_info_plists() -> None:
    # iOS app
    write(ROOT / "ScreenTimeScheduler/App/iOS/Info.plist",
          info_plist_ios("com.example.sts", "ScreenTimeScheduler"))
    # macOS app
    write(ROOT / "ScreenTimeScheduler/App/macOS/Info.plist",
          info_plist("com.example.sts", "ScreenTimeScheduler"))

    for ext, point in EXT_POINTS.items():
        short = ext.replace("Extension", "Ext")
        write(ROOT / f"ScreenTimeScheduler/Extensions/{ext}/iOS/Info.plist",
              info_plist_ios(f"com.example.sts.{ext}",
                             ext,
                             EXT_IOS_EXTRA.format(point=point)))
        write(ROOT / f"ScreenTimeScheduler/Extensions/{ext}/macOS/Info.plist",
              info_plist(f"com.example.sts.{ext}",
                         ext,
                         EXT_MACOS_EXTRA.format(point=point)))


# ──────────────────────────────────────────────────────────────────────────────
# Assets.xcassets placeholder
# ──────────────────────────────────────────────────────────────────────────────

def write_assets() -> None:
    for subdir in ("App/iOS", "App/macOS"):
        base = ROOT / f"ScreenTimeScheduler/{subdir}/Assets.xcassets"
        write(base / "Contents.json", """\
            {
              "info" : {
                "author" : "xcode",
                "version" : 1
              }
            }
        """)
        write(base / "AppIcon.appiconset/Contents.json", """\
            {
              "images" : [],
              "info" : {
                "author" : "xcode",
                "version" : 1
              }
            }
        """)


# ──────────────────────────────────────────────────────────────────────────────
# project.pbxproj
# ──────────────────────────────────────────────────────────────────────────────

def make_pbxproj() -> str:
    # We define all objects programmatically, then render.

    # ── File references ──────────────────────────────────────────────────────
    # (name, path, last_known_file_type, source_tree)
    file_refs: dict[str, dict] = {}   # id -> attrs

    def fref(name: str, path: str, ftype: str, tree: str = "\"<group>\"") -> str:
        i = gid()
        file_refs[i] = {"name": name, "path": path, "type": ftype, "tree": tree}
        return i

    # iOS App sources
    ios_app_swift   = fref("ScreenTimeSchedulerApp.swift",
                           "App/iOS/ScreenTimeSchedulerApp.swift",
                           "sourcecode.swift")
    ios_cv_swift    = fref("ContentView.swift",
                           "App/iOS/ContentView.swift",
                           "sourcecode.swift")
    ios_info        = fref("Info.plist",
                           "App/iOS/Info.plist",
                           "text.plist.xml")
    ios_ent         = fref("ScreenTimeScheduler.entitlements",
                           "App/iOS/ScreenTimeScheduler.entitlements",
                           "text.plist.entitlements")
    ios_assets      = fref("Assets.xcassets",
                           "App/iOS/Assets.xcassets",
                           "folder.assetcatalog")

    # macOS App sources
    mac_app_swift   = fref("ScreenTimeSchedulerApp.swift",
                           "App/macOS/ScreenTimeSchedulerApp.swift",
                           "sourcecode.swift")
    mac_cv_swift    = fref("ContentView.swift",
                           "App/macOS/ContentView.swift",
                           "sourcecode.swift")
    mac_info        = fref("Info.plist",
                           "App/macOS/Info.plist",
                           "text.plist.xml")
    mac_ent         = fref("ScreenTimeSchedulerMac.entitlements",
                           "App/macOS/ScreenTimeSchedulerMac.entitlements",
                           "text.plist.entitlements")
    mac_assets      = fref("Assets.xcassets",
                           "App/macOS/Assets.xcassets",
                           "folder.assetcatalog")

    # Core
    core_placeholder = fref("Placeholder.swift",
                             "Core/Placeholder.swift",
                             "sourcecode.swift")

    # Extensions
    ext_frefs: dict[str, dict] = {}
    for ext in ("DeviceActivityMonitorExtension",
                "ShieldConfigurationExtension",
                "ShieldActionExtension"):
        for plat in ("iOS", "macOS"):
            key = f"{ext}_{plat}"
            ext_frefs[key] = {
                "swift": fref(f"{ext}.swift",
                              f"Extensions/{ext}/{plat}/{ext}.swift",
                              "sourcecode.swift"),
                "info":  fref("Info.plist",
                              f"Extensions/{ext}/{plat}/Info.plist",
                              "text.plist.xml"),
                "ent":   fref(f"{ext}.entitlements",
                              f"Extensions/{ext}/{plat}/{ext}.entitlements",
                              "text.plist.entitlements"),
            }

    # ── Build files (file ref -> build file id) ──────────────────────────────
    build_files: dict[str, dict] = {}  # id -> {"fileRef": id, "comment": str}

    def bfile(ref_id: str, comment: str) -> str:
        i = gid()
        build_files[i] = {"fileRef": ref_id, "comment": comment}
        return i

    # iOS app build files
    ios_bf_app   = bfile(ios_app_swift,  "ScreenTimeSchedulerApp.swift in Sources")
    ios_bf_cv    = bfile(ios_cv_swift,   "ContentView.swift in Sources")
    ios_bf_res   = bfile(ios_assets,     "Assets.xcassets in Resources")
    ios_bf_core  = bfile(core_placeholder, "Placeholder.swift in Sources")

    # macOS app build files
    mac_bf_app   = bfile(mac_app_swift,  "ScreenTimeSchedulerApp.swift in Sources")
    mac_bf_cv    = bfile(mac_cv_swift,   "ContentView.swift in Sources")
    mac_bf_res   = bfile(mac_assets,     "Assets.xcassets in Resources")
    mac_bf_core  = bfile(core_placeholder, "Placeholder.swift in Sources")

    # Extension build files
    ext_bfiles: dict[str, dict] = {}
    for ext in ("DeviceActivityMonitorExtension",
                "ShieldConfigurationExtension",
                "ShieldActionExtension"):
        for plat in ("iOS", "macOS"):
            key = f"{ext}_{plat}"
            ext_bfiles[key] = {
                "swift": bfile(ext_frefs[key]["swift"],
                               f"{ext}.swift in Sources"),
                "res":   bfile(ext_frefs[key]["info"],
                               f"Info.plist in Resources"),
            }

    # ── Build phases ─────────────────────────────────────────────────────────
    phases: dict[str, dict] = {}

    def sources_phase(files: list[str]) -> str:
        i = gid()
        phases[i] = {"isa": "PBXSourcesBuildPhase", "files": files}
        return i

    def resources_phase(files: list[str]) -> str:
        i = gid()
        phases[i] = {"isa": "PBXResourcesBuildPhase", "files": files}
        return i

    def frameworks_phase(files: list[str] = None) -> str:
        i = gid()
        phases[i] = {"isa": "PBXFrameworksBuildPhase", "files": files or []}
        return i

    ios_src_phase = sources_phase([ios_bf_app, ios_bf_cv, ios_bf_core])
    ios_res_phase = resources_phase([ios_bf_res])
    ios_fw_phase  = frameworks_phase()

    mac_src_phase = sources_phase([mac_bf_app, mac_bf_cv, mac_bf_core])
    mac_res_phase = resources_phase([mac_bf_res])
    mac_fw_phase  = frameworks_phase()

    ext_phases: dict[str, dict] = {}
    for ext in ("DeviceActivityMonitorExtension",
                "ShieldConfigurationExtension",
                "ShieldActionExtension"):
        for plat in ("iOS", "macOS"):
            key = f"{ext}_{plat}"
            ext_phases[key] = {
                "src": sources_phase([ext_bfiles[key]["swift"]]),
                "res": resources_phase([ext_bfiles[key]["res"]]),
                "fw":  frameworks_phase(),
            }

    # ── Build configurations ─────────────────────────────────────────────────
    configs: dict[str, dict] = {}

    def xc_config(name: str, settings: dict) -> str:
        i = gid()
        configs[i] = {"name": name, "settings": settings}
        return i

    def config_list(build_type: str, debug_id: str, release_id: str,
                    default: str = "Release") -> str:
        i = gid()
        configs[i] = {
            "isa": "XCConfigurationList",
            "buildType": build_type,
            "debug": debug_id,
            "release": release_id,
            "default": default,
        }
        return i

    # Project-level configurations
    proj_debug = xc_config("Debug", {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": '"DEBUG=1 $(inherited)"',
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_VERSION": "5.0",
    })
    proj_release = xc_config("Release", {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_NS_ASSERTIONS": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_VERSION": "5.0",
        "VALIDATE_PRODUCT": "YES",
    })
    proj_config_list = config_list("PBXProject", proj_debug, proj_release)

    # iOS App configs
    ios_debug = xc_config("Debug", {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_ENTITLEMENTS": '"ScreenTimeScheduler/App/iOS/ScreenTimeScheduler.entitlements"',
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": '"ScreenTimeScheduler/App/iOS/Info.plist"',
        "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
        "MARKETING_VERSION": '"1.0"',
        "PRODUCT_BUNDLE_IDENTIFIER": '"com.example.sts"',
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SDKROOT": "iphoneos",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    })
    ios_release = xc_config("Release", {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_ENTITLEMENTS": '"ScreenTimeScheduler/App/iOS/ScreenTimeScheduler.entitlements"',
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": '"ScreenTimeScheduler/App/iOS/Info.plist"',
        "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
        "MARKETING_VERSION": '"1.0"',
        "PRODUCT_BUNDLE_IDENTIFIER": '"com.example.sts"',
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SDKROOT": "iphoneos",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    })
    ios_config_list = config_list("PBXNativeTarget", ios_debug, ios_release)

    # macOS App configs
    mac_debug = xc_config("Debug", {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_ENTITLEMENTS": '"ScreenTimeScheduler/App/macOS/ScreenTimeSchedulerMac.entitlements"',
        "CODE_SIGN_STYLE": "Automatic",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": '"ScreenTimeScheduler/App/macOS/Info.plist"',
        "MACOSX_DEPLOYMENT_TARGET": "13.0",
        "MARKETING_VERSION": '"1.0"',
        "PRODUCT_BUNDLE_IDENTIFIER": '"com.example.sts"',
        "PRODUCT_NAME": "ScreenTimeSchedulerMac",
        "SDKROOT": "macosx",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
    })
    mac_release = xc_config("Release", {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_ENTITLEMENTS": '"ScreenTimeScheduler/App/macOS/ScreenTimeSchedulerMac.entitlements"',
        "CODE_SIGN_STYLE": "Automatic",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": '"ScreenTimeScheduler/App/macOS/Info.plist"',
        "MACOSX_DEPLOYMENT_TARGET": "13.0",
        "MARKETING_VERSION": '"1.0"',
        "PRODUCT_BUNDLE_IDENTIFIER": '"com.example.sts"',
        "PRODUCT_NAME": "ScreenTimeSchedulerMac",
        "SDKROOT": "macosx",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
    })
    mac_config_list = config_list("PBXNativeTarget", mac_debug, mac_release)

    # Extension configs
    ext_config_ids: dict[str, dict] = {}
    for ext in ("DeviceActivityMonitorExtension",
                "ShieldConfigurationExtension",
                "ShieldActionExtension"):
        for plat in ("iOS", "macOS"):
            key = f"{ext}_{plat}"
            bid = f"com.example.sts.{ext}"
            if plat == "iOS":
                base = {
                    "CODE_SIGN_ENTITLEMENTS": f'"ScreenTimeScheduler/Extensions/{ext}/{plat}/{ext}.entitlements"',
                    "CODE_SIGN_STYLE": "Automatic",
                    "CURRENT_PROJECT_VERSION": "1",
                    "GENERATE_INFOPLIST_FILE": "NO",
                    "INFOPLIST_FILE": f'"ScreenTimeScheduler/Extensions/{ext}/{plat}/Info.plist"',
                    "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
                    "MARKETING_VERSION": '"1.0"',
                    "PRODUCT_BUNDLE_IDENTIFIER": f'"{bid}"',
                    "PRODUCT_NAME": f'"{ext}"',
                    "SDKROOT": "iphoneos",
                    "SKIP_INSTALL": "YES",
                    "SWIFT_VERSION": "5.0",
                    "TARGETED_DEVICE_FAMILY": '"1,2"',
                }
            else:
                base = {
                    "CODE_SIGN_ENTITLEMENTS": f'"ScreenTimeScheduler/Extensions/{ext}/{plat}/{ext}.entitlements"',
                    "CODE_SIGN_STYLE": "Automatic",
                    "CURRENT_PROJECT_VERSION": "1",
                    "GENERATE_INFOPLIST_FILE": "NO",
                    "INFOPLIST_FILE": f'"ScreenTimeScheduler/Extensions/{ext}/{plat}/Info.plist"',
                    "MACOSX_DEPLOYMENT_TARGET": "13.0",
                    "MARKETING_VERSION": '"1.0"',
                    "PRODUCT_BUNDLE_IDENTIFIER": f'"{bid}"',
                    "PRODUCT_NAME": f'"{ext}Mac"',
                    "SDKROOT": "macosx",
                    "SKIP_INSTALL": "YES",
                    "SWIFT_VERSION": "5.0",
                }
            d = xc_config("Debug",   {**base})
            r = xc_config("Release", {**base})
            cl = config_list("PBXNativeTarget", d, r)
            ext_config_ids[key] = cl

    # ── Targets ──────────────────────────────────────────────────────────────
    targets: dict[str, dict] = {}

    def native_target(name: str, product_type: str, product_name: str,
                      src_phase: str, res_phase: str, fw_phase: str,
                      config_list_id: str) -> str:
        i = gid()
        targets[i] = {
            "name": name,
            "productType": product_type,
            "productName": product_name,
            "phases": [src_phase, res_phase, fw_phase],
            "configList": config_list_id,
        }
        return i

    ios_target = native_target(
        "ScreenTimeScheduler", '"com.apple.product-type.application"',
        "ScreenTimeScheduler",
        ios_src_phase, ios_res_phase, ios_fw_phase, ios_config_list,
    )
    mac_target = native_target(
        "ScreenTimeSchedulerMac", '"com.apple.product-type.application"',
        "ScreenTimeSchedulerMac",
        mac_src_phase, mac_res_phase, mac_fw_phase, mac_config_list,
    )

    ext_target_ids: dict[str, str] = {}
    product_type_map = {
        "DeviceActivityMonitorExtension":
            '"com.apple.product-type.extensionkit.extension"',
        "ShieldConfigurationExtension":
            '"com.apple.product-type.extensionkit.extension"',
        "ShieldActionExtension":
            '"com.apple.product-type.extensionkit.extension"',
    }
    for ext in ("DeviceActivityMonitorExtension",
                "ShieldConfigurationExtension",
                "ShieldActionExtension"):
        for plat in ("iOS", "macOS"):
            key = f"{ext}_{plat}"
            suffix = "" if plat == "iOS" else "Mac"
            t = native_target(
                f"{ext}{suffix}",
                product_type_map[ext],
                f"{ext}{suffix}",
                ext_phases[key]["src"],
                ext_phases[key]["res"],
                ext_phases[key]["fw"],
                ext_config_ids[key],
            )
            ext_target_ids[key] = t

    all_target_ids = [ios_target, mac_target] + list(ext_target_ids.values())

    # ── Groups ───────────────────────────────────────────────────────────────
    groups: dict[str, dict] = {}

    def group(name: str, path: str, children: list[str],
              tree: str = '"<group>"') -> str:
        i = gid()
        groups[i] = {"name": name, "path": path, "children": children,
                     "tree": tree}
        return i

    # Core group
    core_grp = group("Core", "ScreenTimeScheduler/Core",
                     [core_placeholder])

    # Extension groups
    ext_grps: dict[str, dict] = {}
    for ext in ("DeviceActivityMonitorExtension",
                "ShieldConfigurationExtension",
                "ShieldActionExtension"):
        ios_key = f"{ext}_iOS"
        mac_key = f"{ext}_macOS"
        ios_grp = group("iOS", f"ScreenTimeScheduler/Extensions/{ext}/iOS",
                        [ext_frefs[ios_key]["swift"],
                         ext_frefs[ios_key]["info"],
                         ext_frefs[ios_key]["ent"]])
        mac_grp = group("macOS", f"ScreenTimeScheduler/Extensions/{ext}/macOS",
                        [ext_frefs[mac_key]["swift"],
                         ext_frefs[mac_key]["info"],
                         ext_frefs[mac_key]["ent"]])
        ext_grp = group(ext, f"ScreenTimeScheduler/Extensions/{ext}",
                        [ios_grp, mac_grp])
        ext_grps[ext] = ext_grp

    extensions_grp = group("Extensions", "ScreenTimeScheduler/Extensions",
                            list(ext_grps.values()))

    # iOS App group
    ios_grp = group("iOS", "ScreenTimeScheduler/App/iOS",
                    [ios_app_swift, ios_cv_swift, ios_assets,
                     ios_info, ios_ent])
    # macOS App group
    mac_grp_id = group("macOS", "ScreenTimeScheduler/App/macOS",
                       [mac_app_swift, mac_cv_swift, mac_assets,
                        mac_info, mac_ent])
    app_grp = group("App", "ScreenTimeScheduler/App",
                    [ios_grp, mac_grp_id])

    sts_grp = group("ScreenTimeScheduler", "ScreenTimeScheduler",
                    [app_grp, core_grp, extensions_grp])

    products_grp = group("Products", None, [], tree='"<group>"')

    root_grp = group("ScreenTimeScheduler", None,
                     [sts_grp, products_grp])

    # ── Project ───────────────────────────────────────────────────────────────
    project_id = gid()

    # ── Render ────────────────────────────────────────────────────────────────
    lines = []

    def L(s: str = "") -> None:
        lines.append(s)

    def settings_block(d: dict) -> str:
        parts = []
        for k, v in d.items():
            parts.append(f"\t\t\t\t{k} = {v};")
        return "\n".join(parts)

    L("// !$*UTF8*$!")
    L("{")
    L("\tarchiveVersion = 1;")
    L("\tclasses = {")
    L("\t};")
    L("\tobjectVersion = 56;")
    L("\tobjects = {")
    L()

    # PBXBuildFile
    L("/* Begin PBXBuildFile section */")
    for bid, ba in build_files.items():
        L(f"\t\t{bid} /* {ba['comment']} */ = "
          f"{{isa = PBXBuildFile; fileRef = {ba['fileRef']}; }};")
    L("/* End PBXBuildFile section */")
    L()

    # PBXFileReference
    L("/* Begin PBXFileReference section */")
    for fid, fa in file_refs.items():
        L(f"\t\t{fid} /* {fa['name']} */ = "
          f"{{isa = PBXFileReference; lastKnownFileType = {fa['type']}; "
          f"name = {fa['name']}; path = {fa['path']}; "
          f"sourceTree = {fa['tree']}; }};")
    L("/* End PBXFileReference section */")
    L()

    # PBXFrameworksBuildPhase
    L("/* Begin PBXFrameworksBuildPhase section */")
    for pid, pa in phases.items():
        if pa["isa"] == "PBXFrameworksBuildPhase":
            files_str = ", ".join(pa["files"])
            L(f"\t\t{pid} = {{")
            L(f"\t\t\tisa = PBXFrameworksBuildPhase;")
            L(f"\t\t\tbuildActionMask = 2147483647;")
            L(f"\t\t\tfiles = ({files_str});")
            L(f"\t\t\trunOnlyForDeploymentPostprocessing = 0;")
            L(f"\t\t}};")
    L("/* End PBXFrameworksBuildPhase section */")
    L()

    # PBXGroup
    L("/* Begin PBXGroup section */")
    for gid_, ga in groups.items():
        L(f"\t\t{gid_} = {{")
        L(f"\t\t\tisa = PBXGroup;")
        L(f"\t\t\tchildren = (")
        for c in ga["children"]:
            L(f"\t\t\t\t{c},")
        L(f"\t\t\t);")
        if ga["path"]:
            L(f"\t\t\tpath = \"{ga['path']}\";")
        if ga["name"]:
            L(f"\t\t\tname = \"{ga['name']}\";")
        L(f"\t\t\tsourceTree = {ga['tree']};")
        L(f"\t\t}};")
    L("/* End PBXGroup section */")
    L()

    # PBXNativeTarget
    L("/* Begin PBXNativeTarget section */")
    for tid, ta in targets.items():
        L(f"\t\t{tid} /* {ta['name']} */ = {{")
        L(f"\t\t\tisa = PBXNativeTarget;")
        L(f"\t\t\tbuildConfigurationList = {ta['configList']};")
        L(f"\t\t\tbuildPhases = (")
        for ph in ta["phases"]:
            L(f"\t\t\t\t{ph},")
        L(f"\t\t\t);")
        L(f"\t\t\tbuildRules = ();")
        L(f"\t\t\tdependencies = ();")
        L(f"\t\t\tname = \"{ta['name']}\";")
        L(f"\t\t\tproductName = \"{ta['productName']}\";")
        L(f"\t\t\tproductType = {ta['productType']};")
        L(f"\t\t}};")
    L("/* End PBXNativeTarget section */")
    L()

    # PBXProject
    L("/* Begin PBXProject section */")
    L(f"\t\t{project_id} /* Project object */ = {{")
    L(f"\t\t\tisa = PBXProject;")
    L(f"\t\t\tattributes = {{")
    L(f"\t\t\t\tLastUpgradeCheck = 1500;")
    L(f"\t\t\t\tTargetAttributes = {{")
    for tid in all_target_ids:
        L(f"\t\t\t\t\t{tid} = {{ CreatedOnToolsVersion = 15.0; }};")
    L(f"\t\t\t\t}};")
    L(f"\t\t\t}};")
    L(f"\t\t\tbuildConfigurationList = {proj_config_list};")
    L(f"\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    L(f"\t\t\tdevelopmentRegion = en;")
    L(f"\t\t\thasScannedForEncodings = 0;")
    L(f"\t\t\tknownRegions = (en, Base);")
    L(f"\t\t\tmainGroup = {root_grp};")
    L(f"\t\t\tproductRefGroup = {products_grp};")
    L(f"\t\t\tprojectDirPath = \"\";")
    L(f"\t\t\tprojectRoot = \"\";")
    L(f"\t\t\ttargets = (")
    for tid in all_target_ids:
        L(f"\t\t\t\t{tid},")
    L(f"\t\t\t);")
    L(f"\t\t}};")
    L("/* End PBXProject section */")
    L()

    # PBXResourcesBuildPhase
    L("/* Begin PBXResourcesBuildPhase section */")
    for pid, pa in phases.items():
        if pa["isa"] == "PBXResourcesBuildPhase":
            L(f"\t\t{pid} = {{")
            L(f"\t\t\tisa = PBXResourcesBuildPhase;")
            L(f"\t\t\tbuildActionMask = 2147483647;")
            L(f"\t\t\tfiles = (")
            for f in pa["files"]:
                L(f"\t\t\t\t{f},")
            L(f"\t\t\t);")
            L(f"\t\t\trunOnlyForDeploymentPostprocessing = 0;")
            L(f"\t\t}};")
    L("/* End PBXResourcesBuildPhase section */")
    L()

    # PBXSourcesBuildPhase
    L("/* Begin PBXSourcesBuildPhase section */")
    for pid, pa in phases.items():
        if pa["isa"] == "PBXSourcesBuildPhase":
            L(f"\t\t{pid} = {{")
            L(f"\t\t\tisa = PBXSourcesBuildPhase;")
            L(f"\t\t\tbuildActionMask = 2147483647;")
            L(f"\t\t\tfiles = (")
            for f in pa["files"]:
                L(f"\t\t\t\t{f},")
            L(f"\t\t\t);")
            L(f"\t\t\trunOnlyForDeploymentPostprocessing = 0;")
            L(f"\t\t}};")
    L("/* End PBXSourcesBuildPhase section */")
    L()

    # XCBuildConfiguration
    L("/* Begin XCBuildConfiguration section */")
    for cid, ca in configs.items():
        if "isa" not in ca:  # XCBuildConfiguration
            L(f"\t\t{cid} /* {ca['name']} */ = {{")
            L(f"\t\t\tisa = XCBuildConfiguration;")
            L(f"\t\t\tbuildSettings = {{")
            for k, v in ca["settings"].items():
                L(f"\t\t\t\t{k} = {v};")
            L(f"\t\t\t}};")
            L(f"\t\t\tname = {ca['name']};")
            L(f"\t\t}};")
    L("/* End XCBuildConfiguration section */")
    L()

    # XCConfigurationList
    L("/* Begin XCConfigurationList section */")
    for cid, ca in configs.items():
        if ca.get("isa") == "XCConfigurationList":
            L(f"\t\t{cid} = {{")
            L(f"\t\t\tisa = XCConfigurationList;")
            L(f"\t\t\tbuildConfigurations = (")
            L(f"\t\t\t\t{ca['debug']} /* Debug */,")
            L(f"\t\t\t\t{ca['release']} /* Release */,")
            L(f"\t\t\t);")
            L(f"\t\t\tdefaultConfigurationIsVisible = 0;")
            L(f"\t\t\tdefaultConfigurationName = {ca['default']};")
            L(f"\t\t}};")
    L("/* End XCConfigurationList section */")
    L()

    L("\t};")
    L(f"\trootObject = {project_id} /* Project object */;")
    L("}")

    return "\n".join(lines)


# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

def main() -> None:
    print("Generating Xcode project skeleton...")

    print("\n=== Source files ===")
    write_sources()

    print("\n=== Entitlements ===")
    write_entitlements()

    print("\n=== Info.plists ===")
    write_info_plists()

    print("\n=== Assets.xcassets ===")
    write_assets()

    print("\n=== project.pbxproj ===")
    pbxproj = make_pbxproj()
    proj_dir = ROOT / "ScreenTimeScheduler.xcodeproj"
    proj_dir.mkdir(parents=True, exist_ok=True)
    (proj_dir / "project.pbxproj").write_text(pbxproj)
    print(f"  wrote ScreenTimeScheduler.xcodeproj/project.pbxproj "
          f"({len(pbxproj):,} bytes)")

    print("\nDone.")


if __name__ == "__main__":
    main()
