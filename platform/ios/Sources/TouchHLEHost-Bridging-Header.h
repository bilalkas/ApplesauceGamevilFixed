#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

// Whether dynarmic can get the executable memory it needs. Without it,
// starting a game kills the app.
bool touchhle_ios_jit_available(void);

// Whether that came from an attached debugger rather than from the
// `dynamic-codesigning` entitlement. A debugger has to be re-attached every
// time the app starts as a new process; the entitlement does not.
bool touchhle_ios_jit_is_from_debugger(void);

// The emulator core lives in a dylib that the app loads at runtime (see
// EmulatorCore.swift), so its entry points are found with dlsym rather than
// declared here. Only the SDL shim below is part of the app binary.

typedef int32_t (*TouchHLEIOSRunGameFn)(
    const char *path,
    int32_t scale_hack,
    int32_t orientation,
    int32_t network_access,
    int32_t analog_stick_tilt_controls
);

int32_t touchhle_ios_launch_game(
    TouchHLEIOSRunGameFn run_game,
    const char *path,
    int32_t scale_hack,
    int32_t orientation,
    int32_t network_access,
    int32_t analog_stick_tilt_controls
);

#ifdef __OBJC__
#import <Foundation/Foundation.h>

// A Home Screen icon for a game is a Web Clip pointing at
// applesauce://launch?file=<name>. SDL owns the scene delegate, so main.m
// intercepts those URLs on their way through
// -[SDLUIKitSceneDelegate sendDropFileForURL:] and parks them here.

// Posted with the NSURL as its object when one arrives while the app is
// already running.
extern NSString *const ApplesauceDidReceiveLaunchURLNotification;

// The URL the app was opened with, if any. On a cold launch the URL is
// delivered before SDL_main runs, so the host reads it on startup rather than
// waiting for the notification it already missed. Taking it clears it, so a
// deep link is never acted on twice.
NSURL *_Nullable touchhle_ios_take_pending_launch_url(void);
#endif
