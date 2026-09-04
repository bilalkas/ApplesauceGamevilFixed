#include <SDL.h>
#include <SDL_system.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

// Each emulator core exports this; the host passes in the one belonging to the
// core it loaded for this game.
typedef int32_t (*TouchHLEIOSRunGameFn)(
    const char *path,
    int32_t scale_hack,
    int32_t orientation,
    int32_t network_access,
    int32_t analog_stick_tilt_controls
);

// Dynarmic needs writable-executable memory, and two things can grant it:
//
//   * An attached debugger (StikDebug, AltJIT, TrollStore's "Enable JIT"),
//     which sets CS_DEBUGGED on the process. This has to be redone every time
//     the app starts as a new process.
//   * The `dynamic-codesigning` entitlement, which makes it permanent. Only
//     TrollStore can grant that, and iOS 15+ only honours it on A11 and older
//     chips.
//
// Checking only for a debugger would tell a TrollStore user with permanent JIT
// that they have none, and hold back a launch that would have worked.

// Not declared in the public SDK, but a stable syscall wrapper in libSystem.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define TOUCHHLE_CS_OPS_STATUS 0
#define TOUCHHLE_CS_DEBUGGED 0x10000000

bool touchhle_ios_jit_is_from_debugger(void) {
    // dynarmic's code allocator asks for its executable memory by executing
    // `brk #0xf00d` (see oaknut's prepare_jit_region), a trap that only an
    // attached debugger can service. With none attached the trap is fatal the
    // instant a game starts, which reads as the app quitting for no reason.
    unsigned int flags = 0;
    if (csops(getpid(), TOUCHHLE_CS_OPS_STATUS, &flags, sizeof(flags)) == 0
        && (flags & TOUCHHLE_CS_DEBUGGED) != 0) {
        return true;
    }

    // P_TRACED is the older signal for the same thing, and is what this app
    // shipped with through 0.3.0. Keep it as a second opinion rather than
    // replace it.
    struct kinfo_proc info;
    info.kp_proc.p_flag = 0;

    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return false;
    }

    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// SecTask lives in Security.framework but is not declared in the iOS SDK.
// Resolve it at runtime so a missing symbol degrades to "no entitlement"
// rather than stopping the app from launching at all.
static bool touchhle_has_boolean_entitlement(CFStringRef name) {
    typedef CFTypeRef (*create_from_self_fn)(CFAllocatorRef);
    typedef CFTypeRef (*copy_entitlement_fn)(CFTypeRef, CFStringRef, CFErrorRef *);

    static create_from_self_fn create_task;
    static copy_entitlement_fn copy_entitlement;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *security = dlopen(
            "/System/Library/Frameworks/Security.framework/Security",
            RTLD_LAZY
        );
        if (security == NULL) {
            return;
        }
        create_task = (create_from_self_fn)dlsym(security, "SecTaskCreateFromSelf");
        copy_entitlement =
            (copy_entitlement_fn)dlsym(security, "SecTaskCopyValueForEntitlement");
    });

    if (create_task == NULL || copy_entitlement == NULL) {
        return false;
    }

    CFTypeRef task = create_task(kCFAllocatorDefault);
    if (task == NULL) {
        return false;
    }
    CFTypeRef value = copy_entitlement(task, name, NULL);
    bool granted = value != NULL
        && CFGetTypeID(value) == CFBooleanGetTypeID()
        && CFBooleanGetValue((CFBooleanRef)value);
    if (value != NULL) {
        CFRelease(value);
    }
    CFRelease(task);
    return granted;
}

static bool touchhle_has_dynamic_codesigning(void) {
    return touchhle_has_boolean_entitlement(CFSTR("dynamic-codesigning"));
}

bool touchhle_ios_jit_available(void) {
    return touchhle_ios_jit_is_from_debugger() || touchhle_has_dynamic_codesigning();
}

// Which of the release IPAs this is, as far as the app can tell from inside.
//
// It matters because the two builds get JIT by different routes, and neither
// route can be started from the other's UI: a sideloaded install uses
// StikDebug's URL scheme, while a TrollStore install uses TrollStore's own
// "Enable JIT", which nothing in this app can trigger. Offering the wrong one
// leaves the user tapping a button that cannot work.
//
// The marker is an entitlement only the TrollStore IPAs carry. A free Apple
// account cannot sign `com.apple.developer.kernel.extended-virtual-addressing`,
// so AltStore, SideStore and Sideloadly installs never have it, and TrollStore
// grants it unconditionally. This is a hint for choosing wording, never a
// safety check: a paid developer account can sign it too, which is why the
// iOS-version test for StikDebug is applied first.
bool touchhle_ios_is_trollstore_install(void) {
    return touchhle_has_boolean_entitlement(
        CFSTR("com.apple.developer.kernel.extended-virtual-addressing")
    );
}

// Do NOT add an mmap PROT_WRITE | PROT_EXEC probe here. Per mmap(2), iOS
// returns a writable-but-not-executable mapping instead of failing when
// MAP_JIT is absent, so that probe reports success with JIT off. A false "JIT
// is on" sends the emulator into a guaranteed freeze with no explanation.
void touchhle_ios_log_jit_status(const char *context) {
    unsigned int flags = 0;
    int result = csops(getpid(), TOUCHHLE_CS_OPS_STATUS, &flags, sizeof(flags));
    fprintf(
        stderr,
        "touchHLE JIT [%s]: available=%d debugger=%d entitlement=%d "
        "trollstore=%d cs_flags=0x%08x csops=%d/%d\n",
        context ? context : "?",
        touchhle_ios_jit_available(),
        touchhle_ios_jit_is_from_debugger(),
        touchhle_has_dynamic_codesigning(),
        touchhle_ios_is_trollstore_install(),
        flags,
        result,
        (result == 0) ? 0 : errno
    );
}

static FILE *diagnostic_log;

static void redirect_diagnostics(void) {
    const char *home = getenv("HOME");
    if (home == NULL) {
        return;
    }

    char log_path[PATH_MAX];
    int length = snprintf(log_path, sizeof(log_path), "%s/Documents/touchhle-host.log", home);
    if (length < 0 || (size_t)length >= sizeof(log_path)) {
        return;
    }

    // If a game hangs, the only way out is to force-quit, and the next launch
    // would truncate the log that recorded the hang. Keep one generation back
    // so the interesting session survives the relaunch needed to retrieve it.
    char previous_path[PATH_MAX];
    length = snprintf(
        previous_path,
        sizeof(previous_path),
        "%s/Documents/touchhle-host-previous.log",
        home
    );
    if (length > 0 && (size_t)length < sizeof(previous_path)) {
        rename(log_path, previous_path);
    }

    diagnostic_log = fopen(log_path, "w");
    if (diagnostic_log == NULL) {
        return;
    }

    setvbuf(diagnostic_log, NULL, _IONBF, 0);
    dup2(fileno(diagnostic_log), STDOUT_FILENO);
    dup2(fileno(diagnostic_log), STDERR_FILENO);
    fprintf(stderr, "touchHLE iOS port diagnostics started\n");
}

// MARK: - applesauce:// deep links
//
// Putting a game on the Home Screen installs a Web Clip that opens
// applesauce://launch?file=<name>. Catching that URL is awkward here because
// SDL, not this file, owns both the UIApplication delegate and the scene
// delegate. What makes it tractable is that SDL funnels every URL the app is
// opened with through a single method: cold launches iterate
// connectionOptions.URLContexts inside -scene:willConnectToSession:options:,
// warm ones arrive at -scene:openURLContexts:, and both end up calling
// -[SDLUIKitSceneDelegate sendDropFileForURL:] (see
// vendor/rust-sdl2/sdl2-sys/SDL/src/video/uikit/SDL_uikitappdelegate.m).
// Swizzling that one method covers both paths.
//
// It has to be installed from +load rather than from main(): on a cold launch
// the scene connects, and the URL is delivered, before SDL calls SDL_main
// (which is what main() below really is). By +load time SDL is already linked
// in, so its class is registered and ready to patch.

NSString *const ApplesauceDidReceiveLaunchURLNotification =
    @"ApplesauceDidReceiveLaunchURLNotification";

// Written by the hook, read once the SwiftUI host is up. Both happen on the
// main thread, so no locking.
//
// Kept as a C string rather than as an NSURL because this file is not built
// with ARC: a bare `static NSURL *` would hold an autoreleased object that is
// gone by the time the host looks at it, and retain/release here would then
// stop compiling the day ARC is turned on. A strdup'd string is right either
// way.
static char *applesauce_pending_launch_url;
static bool applesauce_url_hook_installed;

static void applesauce_set_pending_launch_url(NSURL *url) {
    free(applesauce_pending_launch_url);
    applesauce_pending_launch_url = NULL;

    const char *text = url.absoluteString.UTF8String;
    if (text != NULL) {
        applesauce_pending_launch_url = strdup(text);
    }
}

NSURL *touchhle_ios_take_pending_launch_url(void) {
    char *raw = applesauce_pending_launch_url;
    if (raw == NULL) {
        return nil;
    }
    applesauce_pending_launch_url = NULL;

    // +URLWithString: hands back an autoreleased URL, which is what Swift
    // expects from an imported function returning an object it did not create.
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:raw]];
    free(raw);
    return url;
}

@interface ApplesauceURLHook : NSObject
@end

@implementation ApplesauceURLHook

+ (void)load {
    Class scene_delegate = NSClassFromString(@"SDLUIKitSceneDelegate");
    if (scene_delegate == Nil) {
        return;
    }

    SEL original_selector = NSSelectorFromString(@"sendDropFileForURL:");
    SEL our_selector = @selector(applesauce_sendDropFileForURL:);

    Method original = class_getInstanceMethod(scene_delegate, original_selector);
    Method ours = class_getInstanceMethod(self, our_selector);
    if (original == NULL || ours == NULL) {
        return;
    }

    // Add our implementation to SDL's class first, so the exchange below stays
    // within one class. Without that step the two methods would live in
    // different classes and the "call through to the original" trick at the
    // bottom of the hook would recurse forever.
    if (!class_addMethod(
            scene_delegate,
            our_selector,
            method_getImplementation(ours),
            method_getTypeEncoding(ours)
        )) {
        return;
    }

    Method added = class_getInstanceMethod(scene_delegate, our_selector);
    if (added == NULL) {
        return;
    }

    method_exchangeImplementations(original, added);
    applesauce_url_hook_installed = true;
}

- (void)applesauce_sendDropFileForURL:(NSURL *)url {
    if ([url.scheme caseInsensitiveCompare:@"applesauce"] == NSOrderedSame) {
        applesauce_set_pending_launch_url(url);
        // The host may or may not be listening yet: on a cold launch this runs
        // before SwiftUI exists, and the pending URL above is what it reads on
        // startup. On a warm one the notification is what gets it moving.
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ApplesauceDidReceiveLaunchURLNotification
                          object:url];
        return;
    }

    // After the exchange this selector carries SDL's original implementation,
    // so anything that is not ours still becomes an SDL drop-file event.
    [self applesauce_sendDropFileForURL:url];
}

@end

static void start_native_host(void) {
    Class host_class = NSClassFromString(@"TouchHLENativeHost");
    SEL selector = NSSelectorFromString(@"start");
    if (host_class == Nil || ![host_class respondsToSelector:selector]) {
        fprintf(stderr, "Could not start the native iOS port UI\n");
        return;
    }

    ((void (*)(id, SEL))objc_msgSend)(host_class, selector);
}

// The emulator's audio comes out of OpenAL Soft, which on iOS drives a
// RemoteIO audio unit directly. Nothing in that path ever touches
// AVAudioSession, so up to now the app played through whatever implicit
// session iOS hands an app that never asked for one: category SoloAmbient,
// silenced by the ring/silent switch, stopped by the lock screen, and with an
// I/O buffer duration the system is free to pick (and to change underneath a
// running audio unit, which is heard as stuttering).
//
// Configure it explicitly, before the emulator gets a chance to open its
// OpenAL device, so the audio unit is created against a session that is
// already active and whose parameters no longer move.
static const char *audio_session_error_text(NSError *error) {
    const char *text = error.localizedDescription.UTF8String;
    return text != NULL ? text : "(no description)";
}

// iOS can also pull the ground out from under an already-running audio unit: a
// phone call or Siri deactivates the session, and connecting headphones or
// AirPods changes the hardware sample rate. OpenAL Soft samples that rate
// exactly once, in CoreAudioPlayback::reset(), and never looks again — so from
// then on it feeds a unit whose parameters have moved, which is heard as
// stuttering, or as audio that simply never comes back after an interruption.
//
// Nothing reachable from here can make OpenAL re-open its device, but
// re-activating the session is what gets the unit running again afterwards.
// Logging both events is what makes it possible to tell from a user's log
// whether any of this happened at all.
static void observe_audio_session_changes(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    AVAudioSession *session = [AVAudioSession sharedInstance];

    [center addObserverForName:AVAudioSessionInterruptionNotification
                        object:session
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
        bool ended =
            type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded;
        fprintf(
            stderr,
            "touchHLE audio session: interruption %s\n",
            ended ? "ended" : "began"
        );
        if (!ended) {
            return;
        }

        NSError *error = nil;
        if (![[AVAudioSession sharedInstance] setActive:YES error:&error]) {
            fprintf(
                stderr,
                "touchHLE audio session: could not reactivate after an "
                "interruption: %s\n",
                audio_session_error_text(error)
            );
        }
    }];

    [center addObserverForName:AVAudioSessionRouteChangeNotification
                        object:session
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        NSNumber *reason = note.userInfo[AVAudioSessionRouteChangeReasonKey];
        AVAudioSession *current = [AVAudioSession sharedInstance];
        fprintf(
            stderr,
            "touchHLE audio session: route changed (reason %lu), now %g Hz, "
            "I/O buffer=%g s, %ld output channel(s)\n",
            (unsigned long)reason.unsignedIntegerValue,
            current.sampleRate,
            current.IOBufferDuration,
            (long)current.outputNumberOfChannels
        );
    }];
}

static void configure_audio_session(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;

    // Launching a second game re-enters this function; the observers belong to
    // the process, not to one game.
    static dispatch_once_t observers_once;
    dispatch_once(&observers_once, ^{
        observe_audio_session_changes();
    });

    // Playback: a game's music and effects should be audible with the mute
    // switch on, like every other iPhone game.
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error]) {
        fprintf(
            stderr,
            "touchHLE audio session: could not set the Playback category: %s\n",
            audio_session_error_text(error)
        );
        error = nil;
    }

    // 23 ms is the classic 1024-frame buffer. The emulator refills OpenAL from
    // its run loop at 60 Hz at best, so a larger buffer is worth more here than
    // low latency; asking for a short one would only make drop-outs likelier.
    if (![session setPreferredIOBufferDuration:0.023 error:&error]) {
        fprintf(
            stderr,
            "touchHLE audio session: could not set the preferred I/O buffer "
            "duration: %s\n",
            audio_session_error_text(error)
        );
        error = nil;
    }

    if (![session setActive:YES error:&error]) {
        fprintf(
            stderr,
            "touchHLE audio session: could not activate: %s\n",
            audio_session_error_text(error)
        );
    }

    fprintf(
        stderr,
        "touchHLE audio session: rate=%g Hz, I/O buffer=%g s, output "
        "channels=%ld, other audio playing=%d\n",
        session.sampleRate,
        session.IOBufferDuration,
        (long)session.outputNumberOfChannels,
        (int)session.secondaryAudioShouldBeSilencedHint
    );
}

int32_t touchhle_ios_launch_game(
    TouchHLEIOSRunGameFn run_game,
    const char *path,
    int32_t scale_hack,
    int32_t orientation,
    int32_t network_access,
    int32_t analog_stick_tilt_controls
) {
    if (run_game == NULL) {
        fprintf(stderr, "touchHLE failed: no emulator core was loaded\n");
        return 1;
    }

    const char *orientation_hint = "Portrait";
    if (orientation == 1) {
        orientation_hint = "LandscapeLeft";
    } else if (orientation == 2) {
        orientation_hint = "LandscapeRight";
    }
    SDL_SetHint(SDL_HINT_ORIENTATIONS, orientation_hint);

    configure_audio_session();

    // Breadcrumbs: the emulator runs on the main thread, so if it hangs the UI
    // freezes with it and the log is the only way to see how far it got.
    touchhle_ios_log_jit_status("game-launch");
    fprintf(
        stderr,
        "touchHLE: entering emulator: scale_hack=%d orientation=%s network=%d "
        "analog_tilt=%d\n",
        scale_hack,
        orientation_hint,
        network_access,
        analog_stick_tilt_controls
    );

    SDL_iPhoneSetEventPump(SDL_TRUE);
    int32_t result = run_game(
        path,
        scale_hack,
        orientation,
        network_access,
        analog_stick_tilt_controls
    );
    SDL_iPhoneSetEventPump(SDL_FALSE);
    SDL_ResetHint(SDL_HINT_ORIENTATIONS);

    fprintf(stderr, "touchHLE: emulator returned %d\n", result);
    return result;
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;

    redirect_diagnostics();
    touchhle_ios_log_jit_status("launch");

    // +load ran long before the log existed, so report the result here.
    fprintf(
        stderr,
        "touchHLE: applesauce:// URL hook installed=%d pending=%s\n",
        applesauce_url_hook_installed,
        applesauce_pending_launch_url ? applesauce_pending_launch_url : "(none)"
    );

    char *base_path = SDL_GetBasePath();
    if (base_path != NULL) {
        chdir(base_path);
        SDL_free(base_path);
    }

    start_native_host();
    return 0;
}
