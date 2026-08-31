//! `NSLog()`, `NSLogv()`

use super::ns_string;
use crate::abi::{DotDotDot, VaList};
use crate::dyld::{export_c_func, FunctionExports};
use crate::libc::stdio::printf::printf_inner;
use crate::objc::id;
use crate::Environment;
use std::sync::{LazyLock, Mutex};

/// The most recent guest log message and how many times it has repeated.
///
/// Apps can be extremely chatty: Zenonia 3 calls `NSLog("NOT_REACHED")` on
/// roughly every frame, which was 1688 of the 2272 lines in a 25-second
/// session. Each one costs blocking writes to both stderr (which the iOS host
/// redirects to a file) and touchHLE_log.txt, and together they bury the lines
/// that actually say something about what the app is doing.
static LAST_MESSAGE: LazyLock<Mutex<(String, u64)>> =
    LazyLock::new(|| Mutex::new((String::new(), 0)));

/// How many times `message` has now been logged in a row, or [None] if this
/// repeat should be suppressed.
///
/// Runs of an identical message are reported on an exponential schedule: the
/// 1st to 8th occurrence, then the 16th, 32nd, 64th and so on, each with the
/// running count attached. Nothing is silently dropped — a run that is still
/// growing keeps producing lines, just ever more rarely — and reporting as we
/// go rather than summarising a finished run means there is no pending count to
/// flush if the app stops logging or crashes mid-run.
fn repeat_to_report(message: &str) -> Option<u64> {
    // Never let a poisoned lock swallow output; logging is the last thing that
    // should fail while something else is already going wrong.
    let Ok(mut last) = LAST_MESSAGE.lock() else {
        return Some(1);
    };
    if last.0 != message {
        last.0.clear();
        last.0.push_str(message);
        last.1 = 1;
        return Some(1);
    }
    last.1 += 1;
    if last.1 <= 8 || last.1.is_power_of_two() {
        Some(last.1)
    } else {
        None
    }
}

fn NSLog(
    env: &mut Environment,
    format: id, // NSString
    args: DotDotDot,
) {
    NSLogv(env, format, args.start());
}

fn NSLogv(
    env: &mut Environment,
    format: id, // NSString
    arg: VaList,
) {
    // TODO: avoid copy
    let format_string = ns_string::to_rust_string(env, format);

    log_dbg!("NSLog({:?} ({:?}), ...)", format, format_string);

    let res = printf_inner::<true, _>(
        env,
        |_, idx| {
            if idx as usize == format_string.len() {
                b'\0'
            } else {
                format_string.as_bytes()[idx as usize]
            }
        },
        arg,
    );
    // TODO: Should we include a timestamp, like the real NSLog?
    let message = format!(
        "{}[{}] {}",
        env.bundle.executable_path().file_name().unwrap(),
        env.current_thread,
        String::from_utf8_lossy(&res)
    );
    match repeat_to_report(&message) {
        Some(1) => echo!("{}", message),
        Some(count) => echo!("{} [repeat {}]", message, count),
        None => (),
    }
}

pub const FUNCTIONS: FunctionExports = &[export_c_func!(NSLog(_, _)), export_c_func!(NSLogv(_, _))];
