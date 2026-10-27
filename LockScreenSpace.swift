import AppKit
#if canImport(SkyLightWindow)
import SkyLightWindow      // https://github.com/Lakr233/SkyLightWindow  (Swift package)
#endif

/// Normal windows are hidden by macOS while the screen is locked. SkyLight (a PRIVATE Apple framework)
/// can put a window in a space above the lock screen.
///  - With the SkyLightWindow package added to the target: uses the package (recommended).
///  - Without it: falls back to calling SkyLight directly through dlsym (less tested).
/// Private API: it can break in any macOS update. Switch it off in the menu: "Show island when locked".
@MainActor
enum LockScreenSpace {
    private static var attached = false

    static func attach(_ window: NSWindow) {
        guard !attached else { return }
        guard window.windowNumber > 0 else { print("LockScreenSpace: window has no number yet"); return }

        #if canImport(SkyLightWindow)
        SkyLightOperator.shared.delegateWindow(window)
        attached = true
        print("LockScreenSpace: delegated window \(window.windowNumber) via SkyLightWindow package")
        #else
        attachWithPrivateAPI(window)
        #endif
    }

    #if !canImport(SkyLightWindow)
    // Space ids are 64-bit (size_t) and the options argument is a pointer.
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate    = @convention(c) (Int32, Int32, UnsafeRawPointer?) -> Int
    private typealias SetLevel       = @convention(c) (Int32, Int, Int32) -> Int32
    private typealias ShowSpaces     = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindows     = @convention(c) (Int32, Int, CFArray, Int32) -> Void

    private static func attachWithPrivateAPI(_ window: NSWindow) {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let pConn   = dlsym(lib, "SLSMainConnectionID"),
              let pCreate = dlsym(lib, "SLSSpaceCreate"),
              let pLevel  = dlsym(lib, "SLSSpaceSetAbsoluteLevel"),
              let pShow   = dlsym(lib, "SLSShowSpaces"),
              let pAdd    = dlsym(lib, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else {
            print("LockScreenSpace: SkyLight symbols not found")
            return
        }
        let connection = unsafeBitCast(pConn, to: MainConnection.self)()
        let space = unsafeBitCast(pCreate, to: SpaceCreate.self)(connection, 1, nil)
        _ = unsafeBitCast(pLevel, to: SetLevel.self)(connection, space, 2_147_483_647)
        unsafeBitCast(pShow, to: ShowSpaces.self)(connection, [NSNumber(value: space)] as CFArray)
        unsafeBitCast(pAdd, to: AddWindows.self)(connection, space,
                                                 [NSNumber(value: window.windowNumber)] as CFArray, 7)
        attached = true
        print("LockScreenSpace: attached window \(window.windowNumber) to space \(space) (dlsym fallback)")
    }
    #endif
}
