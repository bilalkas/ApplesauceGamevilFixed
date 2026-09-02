/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

//! `NSException`.
//!
//! Provides a host-side implementation of NSException including `raise`,
//! `description`, copy semantics, and the uncaught-exception handler stub.
//!
//! ### On `raise`
//! In real Objective-C, `-[NSException raise]` is `objc_exception_throw(self)`:
//! it unwinds the call stack to the enclosing `@catch`, and if there is none it
//! calls the uncaught-exception handler and aborts. touchHLE has no unwinder,
//! so we use the same frame-pointer approximation as the C++ exception bypass
//! (see [crate::libc::cxxabi]): the guest function that raised is made to
//! return 0/nil to *its* caller. The `@catch` block itself never runs and
//! `@finally` is skipped, but the throw does leave the function that decided it
//! cannot continue, which is what guest error handling relies on.
//!
//! Simply returning to the raiser — what this file used to do — is much worse:
//! the guest carries on inside a function that has already given up. Zenonia 2
//! shows the failure mode clearly. When Gamevil's (long dead) profile server
//! doesn't answer, its socket wrapper raises `Socket: Send failed`, `-raise`
//! returns, the wrapper retries, and the main thread wedges in an endless raise
//! loop until iOS' watchdog kills the app.

use crate::dyld::{ConstantExports, FunctionExports, HostConstant};
use crate::libc::cxxabi::{note_exception_throw, unwind_to_app_frame, THROW_LOOP_LIMIT};
use crate::mem::MutVoidPtr;
use crate::objc::{
    autorelease, id, msg, msg_class, nil, objc_classes, release, retain, ClassExports, HostObject,
    NSZonePtr,
};
use crate::{export_c_func, Environment};

// ---------------------------------------------------------------------------
// Host object
// ---------------------------------------------------------------------------

#[derive(Default)]
struct NSExceptionHostObject {
    name: id,      // NSString*
    reason: id,    // NSString*
    user_info: id, // NSDictionary*  (may be nil)
}
impl HostObject for NSExceptionHostObject {}

// ---------------------------------------------------------------------------
// Helper: convert an ObjC NSString* to a Rust String safely.
// If the id is nil, returns the provided fallback.
// ---------------------------------------------------------------------------
fn objc_str(env: &mut Environment, s: id, fallback: &str) -> String {
    if s == nil {
        return fallback.to_string();
    }
    super::ns_string::to_rust_string(env, s).into_owned()
}

/// Shared implementation of `-[NSException raise]` and
/// `+[NSException raise:format:]`: log the exception, then approximate the
/// unwind (see the module comment).
///
/// This must only be called from a host method that the guest invoked
/// directly, never from inside a host-initiated `msg![]` — see
/// [unwind_to_app_frame] for why. That is the reason `+raise:format:` calls
/// this instead of sending `-raise` to the exception it just built.
fn raise_and_unwind(env: &mut Environment, exception: id) {
    let (name, reason, user_info) = {
        let host = env.objc.borrow::<NSExceptionHostObject>(exception);
        (host.name, host.reason, host.user_info)
    };
    let name_s = objc_str(env, name, "<unnamed exception>");
    let reason_s = objc_str(env, reason, "<no reason>");

    // Rate-limit the log. A guest stuck in a raise loop would otherwise spend
    // all of its time writing to the log, which on its own is enough to make
    // the app look frozen.
    let count = note_exception_throw(&format!("nsexception:{}", name_s));
    let should_log = count <= 3 || count.is_multiple_of(64);
    if should_log {
        log!(
            "GUEST NSException raised (consecutive #{}): name={:?}, reason={:?}{}",
            count,
            name_s,
            reason_s,
            if user_info != nil {
                ", userInfo=<present>"
            } else {
                ""
            }
        );
    }

    if count >= THROW_LOOP_LIMIT {
        if should_log {
            log!(
                "Warning: NSException loop detected ({:?} raised {} times in a \
                 row). Returning to the raiser to break the loop; the guest will \
                 likely abort or hang shortly.",
                name_s,
                count
            );
        }
        return;
    }

    if !unwind_to_app_frame(env) && should_log {
        log!(
            "Warning: could not unwind past NSException {:?}; no app-level frame \
             on the stack. Returning to the raiser; the guest will likely abort.",
            name_s
        );
    }
}

#[derive(Default)]
pub struct State {
    pub uncaught_exception_handler: MutVoidPtr,
}


pub const CLASSES: ClassExports = objc_classes! {

(env, this, _cmd);

@implementation NSException: NSObject

// MARK: - Alloc

+ (id)allocWithZone:(NSZonePtr)_zone {
    let host_object = Box::new(NSExceptionHostObject {
        name:      nil,
        reason:    nil,
        user_info: nil,
    });
    env.objc.alloc_object(this, host_object, &mut env.mem)
}

// MARK: - Factory / convenience constructors

+ (id)exceptionWithName:(id)name      // NSString*
                 reason:(id)reason    // NSString*
               userInfo:(id)user_info // NSDictionary*  (may be nil)
{
    let obj: id = msg_class![env; NSException alloc];
    let obj: id = msg![env; obj initWithName:name reason:reason userInfo:user_info];
    autorelease(env, obj)
}

// `+raise:format:` — convenience that creates and immediately raises.
// The `format` parameter is treated as a plain reason string (no printf
// substitution) because varargs are not supported in touchHLE HLE stubs.
// Note this deliberately does *not* send `-raise` to the new exception: the
// unwind has to happen in the host method the guest called, not in a nested
// host-to-host message send.
+ (())raise:(id)name   // NSString*  (exception name)
       format:(id)fmt  // NSString*  (reason / format string)
{
    let exc: id = msg_class![env; NSException exceptionWithName:name
                                                         reason:fmt
                                                       userInfo:nil];
    raise_and_unwind(env, exc);
}

// MARK: - Designated initialiser

- (id)initWithName:(id)name      // NSString*
            reason:(id)reason    // NSString*
          userInfo:(id)user_info // NSDictionary*  (may be nil)
{
    retain(env, name);
    retain(env, reason);
    retain(env, user_info);
    {
        let host = env.objc.borrow_mut::<NSExceptionHostObject>(this);
        host.name      = name;
        host.reason    = reason;
        host.user_info = user_info;
    }
    this
}

// MARK: - Accessors

- (id)name {
    env.objc.borrow::<NSExceptionHostObject>(this).name
}

- (id)reason {
    env.objc.borrow::<NSExceptionHostObject>(this).reason
}

- (id)userInfo {
    env.objc.borrow::<NSExceptionHostObject>(this).user_info
}

// Returns an empty array — we have no guest stack-trace support.
- (id)callStackSymbols {
    msg_class![env; NSArray array]
}

// Returns an empty array — same reason.
- (id)callStackReturnAddresses {
    msg_class![env; NSArray array]
}

// MARK: - raise

- (())raise {
    raise_and_unwind(env, this);
}

// MARK: - NSCopying

// NSException is documented as immutable once created, so `copy` just
// retains and returns `self` (same as NSString / NSArray behaviour).
- (id)copy {
    retain(env, this);
    this
}

- (id)copyWithZone:(NSZonePtr)_zone {
    retain(env, this);
    this
}

// MARK: - description

- (id)description {
    let name   = env.objc.borrow::<NSExceptionHostObject>(this).name;
    let reason = env.objc.borrow::<NSExceptionHostObject>(this).reason;
    let name_s   = objc_str(env, name,   "<unnamed>");
    let reason_s = objc_str(env, reason, "<no reason>");
    let s = format!("NSException: name=\"{}\" reason=\"{}\"", name_s, reason_s);
    let ns = super::ns_string::from_rust_string(env, s);
    autorelease(env, ns)
}

// MARK: - Dealloc

- (())dealloc {
    let host = env.objc.borrow::<NSExceptionHostObject>(this);
    let (name, reason, user_info) = (host.name, host.reason, host.user_info);
    release(env, name);
    release(env, reason);
    release(env, user_info);
    env.objc.dealloc_object(this, &mut env.mem);
}

@end

};

// ---------------------------------------------------------------------------
// NSExceptionName string constants
// ---------------------------------------------------------------------------

pub const CONSTANTS: ConstantExports = &[
    (
        "_NSCharacterConversionException",
        HostConstant::NSString("NSCharacterConversionException"),
    ),
    (
        "_NSDecimalNumberDivideByZeroException",
        HostConstant::NSString("NSDecimalNumberDivideByZeroException"),
    ),
    (
        "_NSDecimalNumberExactnessException",
        HostConstant::NSString("NSDecimalNumberExactnessException"),
    ),
    (
        "_NSDecimalNumberOverflowException",
        HostConstant::NSString("NSDecimalNumberOverflowException"),
    ),
    (
        "_NSDecimalNumberUnderflowException",
        HostConstant::NSString("NSDecimalNumberUnderflowException"),
    ),
    (
        "_NSDestinationInvalidException",
        HostConstant::NSString("NSDestinationInvalidException"),
    ),
    (
        "_NSFileHandleOperationException",
        HostConstant::NSString("NSFileHandleOperationException"),
    ),
    (
        "_NSGenericException",
        HostConstant::NSString("NSGenericException"),
    ),
    (
        "_NSInternalInconsistencyException",
        HostConstant::NSString("NSInternalInconsistencyException"),
    ),
    (
        "_NSInvalidArchiveOperationException",
        HostConstant::NSString("NSInvalidArchiveOperationException"),
    ),
    (
        "_NSInvalidArgumentException",
        HostConstant::NSString("NSInvalidArgumentException"),
    ),
    (
        "_NSInvalidReceivePortException",
        HostConstant::NSString("NSInvalidReceivePortException"),
    ),
    (
        "_NSInvalidSendPortException",
        HostConstant::NSString("NSInvalidSendPortException"),
    ),
    (
        "_NSInvalidUnarchiveOperationException",
        HostConstant::NSString("NSInvalidUnarchiveOperationException"),
    ),
    (
        "_NSInvocationOperationCancelledException",
        HostConstant::NSString("NSInvocationOperationCancelledException"),
    ),
    (
        "_NSInvocationOperationVoidResultException",
        HostConstant::NSString("NSInvocationOperationVoidResultException"),
    ),
    (
        "_NSMallocException",
        HostConstant::NSString("NSMallocException"),
    ),
    (
        "_NSObjectInaccessibleException",
        HostConstant::NSString("NSObjectInaccessibleException"),
    ),
    (
        "_NSObjectNotAvailableException",
        HostConstant::NSString("NSObjectNotAvailableException"),
    ),
    (
        "_NSOldStyleException",
        HostConstant::NSString("NSOldStyleException"),
    ),
    (
        "_NSParseErrorException",
        HostConstant::NSString("NSParseErrorException"),
    ),
    (
        "_NSPortReceiveException",
        HostConstant::NSString("NSPortReceiveException"),
    ),
    (
        "_NSPortSendException",
        HostConstant::NSString("NSPortSendException"),
    ),
    (
        "_NSPortTimeoutException",
        HostConstant::NSString("NSPortTimeoutException"),
    ),
    (
        "_NSRangeException",
        HostConstant::NSString("NSRangeException"),
    ),
    (
        "_NSUndefinedKeyException",
        HostConstant::NSString("NSUndefinedKeyException"),
    ),
    (
        "_NSInconsistentArchiveException",
        HostConstant::NSString("NSInconsistentArchiveException"),
    ),
    (
        "_NSPPDIncludeNotFoundException",
        HostConstant::NSString("NSPPDIncludeNotFoundException"),
    ),
    (
        "_NSPPDIncludeStackOverflowException",
        HostConstant::NSString("NSPPDIncludeStackOverflowException"),
    ),
    (
        "_NSPPDIncludeStackUnderflowException",
        HostConstant::NSString("NSPPDIncludeStackUnderflowException"),
    ),
    (
        "_NSPPDParseException",
        HostConstant::NSString("NSPPDParseException"),
    ),
    (
        "_NSRTFPropertyStackOverflowException",
        HostConstant::NSString("NSRTFPropertyStackOverflowException"),
    ),
    (
        "_NSTIFFException",
        HostConstant::NSString("NSTIFFException"),
    ),
    (
        "_NSAbortModalException",
        HostConstant::NSString("NSAbortModalException"),
    ),
    (
        "_NSAbortPrintingException",
        HostConstant::NSString("NSAbortPrintingException"),
    ),
    (
        "_NSAccessibilityException",
        HostConstant::NSString("NSAccessibilityException"),
    ),
    (
        "_NSAppKitIgnoredException",
        HostConstant::NSString("NSAppKitIgnoredException"),
    ),
    (
        "_NSAppKitVirtualMemoryException",
        HostConstant::NSString("NSAppKitVirtualMemoryException"),
    ),
    (
        "_NSBadBitmapParametersException",
        HostConstant::NSString("NSBadBitmapParametersException"),
    ),
    (
        "_NSBadComparisonException",
        HostConstant::NSString("NSBadComparisonException"),
    ),
    (
        "_NSBadRTFColorTableException",
        HostConstant::NSString("NSBadRTFColorTableException"),
    ),
    (
        "_NSBadRTFDirectiveException",
        HostConstant::NSString("NSBadRTFDirectiveException"),
    ),
    (
        "_NSBadRTFFontTableException",
        HostConstant::NSString("NSBadRTFFontTableException"),
    ),
    (
        "_NSBadRTFStyleSheetException",
        HostConstant::NSString("NSBadRTFStyleSheetException"),
    ),
    (
        "_NSBrowserIllegalDelegateException",
        HostConstant::NSString("NSBrowserIllegalDelegateException"),
    ),
    (
        "_NSColorListIOException",
        HostConstant::NSString("NSColorListIOException"),
    ),
    (
        "_NSColorListNotEditableException",
        HostConstant::NSString("NSColorListNotEditableException"),
    ),
    (
        "_NSDraggingException",
        HostConstant::NSString("NSDraggingException"),
    ),
    (
        "_NSFontUnavailableException",
        HostConstant::NSString("NSFontUnavailableException"),
    ),
    (
        "_NSIllegalSelectorException",
        HostConstant::NSString("NSIllegalSelectorException"),
    ),
    (
        "_NSImageCacheException",
        HostConstant::NSString("NSImageCacheException"),
    ),
    (
        "_NSNibLoadingException",
        HostConstant::NSString("NSNibLoadingException"),
    ),
    (
        "_NSPasteboardCommunicationException",
        HostConstant::NSString("NSPasteboardCommunicationException"),
    ),
    (
        "_NSPrintOperationExistsException",
        HostConstant::NSString("NSPrintOperationExistsException"),
    ),
    (
        "_NSPrintPackageException",
        HostConstant::NSString("NSPrintPackageException"),
    ),
    (
        "_NSPrintingCommunicationException",
        HostConstant::NSString("NSPrintingCommunicationException"),
    ),
    (
        "_NSTextLineTooLongException",
        HostConstant::NSString("NSTextLineTooLongException"),
    ),
    (
        "_NSTextNoSelectionException",
        HostConstant::NSString("NSTextNoSelectionException"),
    ),
    (
        "_NSTextReadException",
        HostConstant::NSString("NSTextReadException"),
    ),
    (
        "_NSTextWriteException",
        HostConstant::NSString("NSTextWriteException"),
    ),
    (
        "_NSTypedStreamVersionException",
        HostConstant::NSString("NSTypedStreamVersionException"),
    ),
    (
        "_NSWindowServerCommunicationException",
        HostConstant::NSString("NSWindowServerCommunicationException"),
    ),
    (
        "_NSWordTablesReadException",
        HostConstant::NSString("NSWordTablesReadException"),
    ),
    (
        "_NSWordTablesWriteException",
        HostConstant::NSString("NSWordTablesWriteException"),
    ),
    // UIKit exception names (placed here for proximity to Foundation
    // exceptions)
    (
        "_UIViewControllerHierarchyInconsistencyException",
        HostConstant::NSString("UIViewControllerHierarchyInconsistencyException"),
    ),
    (
        "_UIApplicationInvalidInterfaceOrientationException",
        HostConstant::NSString("UIApplicationInvalidInterfaceOrientationException"),
    ),
];

// ---------------------------------------------------------------------------
// C functions: NSSetUncaughtExceptionHandler / NSGetUncaughtExceptionHandler
// ---------------------------------------------------------------------------

/// Registers a last-chance exception handler. In touchHLE all unhandled
/// exceptions are already converted to Rust panics or bypassed, but we
/// save the handler address to maintain accurate guest state and so that
/// `NSGetUncaughtExceptionHandler` can return whatever was last installed.
/// <https://developer.apple.com/documentation/foundation/1409609-nssetuncaughtexceptionhandler>
fn NSSetUncaughtExceptionHandler(env: &mut Environment, handler: MutVoidPtr) {
    env.framework_state
        .foundation
        .ns_exception
        .uncaught_exception_handler = handler;

    log!(
        "NSSetUncaughtExceptionHandler: registered handler at {:?}",
        handler
    );
}

/// Returns the function pointer previously installed via
/// `NSSetUncaughtExceptionHandler`, or `NULL` if no handler has been
/// installed in this process. Apple crash-reporting libraries (PLCrashReporter,
/// Crashlytics, Flurry, …) call this on init so they can chain to any
/// existing handler instead of clobbering it.
/// <https://developer.apple.com/documentation/foundation/1416853-nsgetuncaughtexceptionhandler>
fn NSGetUncaughtExceptionHandler(env: &mut Environment) -> MutVoidPtr {
    let handler = env
        .framework_state
        .foundation
        .ns_exception
        .uncaught_exception_handler;
    log_dbg!(
        "NSGetUncaughtExceptionHandler -> {:?}",
        handler
    );
    handler
}

pub const FUNCTIONS: FunctionExports = &[
    export_c_func!(NSSetUncaughtExceptionHandler(_)),
    export_c_func!(NSGetUncaughtExceptionHandler()),
];
