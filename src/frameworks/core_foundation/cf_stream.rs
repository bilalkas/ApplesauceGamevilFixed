/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! `CFStream` — `CFReadStream` and `CFWriteStream`.
//!
//! The socket/network variants are stubs, but file streams created by
//! `CFReadStreamCreateWithFile` are backed by a real guest file descriptor:
//! Gamevil's WIPI-to-iOS wrapper (Zenonia 3/4) loads every `.zt1` resource
//! through `CFBundleCopyResourceURL` + `CFReadStreamCreateWithFile`.

use crate::dyld::{export_c_func, ConstantExports, FunctionExports, HostConstant};
use crate::frameworks::core_foundation::cf_allocator::CFAllocatorRef;
use crate::frameworks::core_foundation::cf_string::CFStringRef;
use crate::frameworks::core_foundation::{CFRelease, CFRetain, CFTypeRef};
use crate::frameworks::foundation::ns_string;
use crate::libc::posix_io;
use crate::mem::{ConstPtr, MutPtr, MutVoidPtr};
use crate::objc::{id, msg, nil, objc_classes, ClassExports, HostObject};
use crate::Environment;

pub type CFReadStreamRef = CFTypeRef;
pub type CFWriteStreamRef = CFTypeRef;

// CFStreamStatus
type CFStreamStatus = i32;
const kCFStreamStatusNotOpen: CFStreamStatus = 0;
const kCFStreamStatusOpening: CFStreamStatus = 1;
const kCFStreamStatusOpen: CFStreamStatus = 2;
const kCFStreamStatusReading: CFStreamStatus = 3;
const kCFStreamStatusWriting: CFStreamStatus = 4;
const kCFStreamStatusAtEnd: CFStreamStatus = 5;
const kCFStreamStatusClosed: CFStreamStatus = 6;
const kCFStreamStatusError: CFStreamStatus = 7;

// CFStreamEventType flags
type CFStreamEventType = u32;
const kCFStreamEventNone: CFStreamEventType = 0;
const kCFStreamEventOpenCompleted: CFStreamEventType = 1;
const kCFStreamEventHasBytesAvailable: CFStreamEventType = 2;
const kCFStreamEventCanAcceptBytes: CFStreamEventType = 4;
const kCFStreamEventErrorOccurred: CFStreamEventType = 8;
const kCFStreamEventEndEncountered: CFStreamEventType = 16;

// CFStreamErrorDomain
type CFStreamErrorDomain = i32;
const kCFStreamErrorDomainCustom: CFStreamErrorDomain = -1;
const kCFStreamErrorDomainPOSIX: CFStreamErrorDomain = 1;
const kCFStreamErrorDomainMacOSStatus: CFStreamErrorDomain = 2;

// Property keys
pub const kCFStreamPropertyDataWritten: &str = "kCFStreamPropertyDataWritten";
pub const kCFStreamPropertyAppendToFile: &str = "kCFStreamPropertyAppendToFile";
pub const kCFStreamPropertyFileCurrentOffset: &str = "kCFStreamPropertyFileCurrentOffset";
pub const kCFStreamPropertySocketNativeHandle: &str = "kCFStreamPropertySocketNativeHandle";
pub const kCFStreamPropertySocketRemoteHostName: &str = "kCFStreamPropertySocketRemoteHostName";
pub const kCFStreamPropertySocketRemotePortNumber: &str = "kCFStreamPropertySocketRemotePortNumber";
pub const kCFStreamPropertyShouldCloseNativeSocket: &str =
    "kCFStreamPropertyShouldCloseNativeSocket";
pub const kCFStreamPropertySSLSettings: &str = "kCFStreamPropertySSLSettings";
pub const kCFStreamSSLLevel: &str = "kCFStreamSSLLevel";
pub const kCFStreamSSLAllowsExpiredCertificates: &str = "kCFStreamSSLAllowsExpiredCertificates";
pub const kCFStreamSSLAllowsExpiredRoots: &str = "kCFStreamSSLAllowsExpiredRoots";
pub const kCFStreamSSLAllowsAnyRoot: &str = "kCFStreamSSLAllowsAnyRoot";
pub const kCFStreamSSLValidatesCertificateChain: &str = "kCFStreamSSLValidatesCertificateChain";
pub const kCFStreamSSLPeerName: &str = "kCFStreamSSLPeerName";
pub const kCFStreamSSLCertificates: &str = "kCFStreamSSLCertificates";
pub const kCFStreamSSLIsServer: &str = "kCFStreamSSLIsServer";
pub const kCFStreamPropertySocketSecurityLevel: &str = "kCFStreamPropertySocketSecurityLevel";
// iOS 5+ post-handshake property keys, per Apple's
// <https://developer.apple.com/documentation/cfnetwork/cfstream/cfstream-constants>.
// `kCFStreamPropertySSLPeerCertificates` returns the peer's certificate chain
// once the TLS handshake has completed; `kCFStreamPropertySSLPeerTrust` is
// the associated `SecTrustRef`; `kCFStreamPropertySSLContext` exposes the
// underlying `SSLContextRef`.
pub const kCFStreamPropertySSLPeerCertificates: &str = "kCFStreamPropertySSLPeerCertificates";
pub const kCFStreamPropertySSLPeerTrust: &str = "kCFStreamPropertySSLPeerTrust";
pub const kCFStreamPropertySSLContext: &str = "kCFStreamPropertySSLContext";
// Stream-socket security-level option values, per
// <https://developer.apple.com/documentation/cfnetwork/cfsocketstream>.
pub const kCFStreamSocketSecurityLevelNone: &str = "kCFStreamSocketSecurityLevelNone";
pub const kCFStreamSocketSecurityLevelSSLv2: &str = "kCFStreamSocketSecurityLevelSSLv2";
pub const kCFStreamSocketSecurityLevelSSLv3: &str = "kCFStreamSocketSecurityLevelSSLv3";
pub const kCFStreamSocketSecurityLevelTLSv1: &str = "kCFStreamSocketSecurityLevelTLSv1";
pub const kCFStreamSocketSecurityLevelNegotiatedSSL: &str =
    "kCFStreamSocketSecurityLevelNegotiatedSSL";

// CFFTPStream property keys, per Apple's CFFTPStream reference:
// <https://developer.apple.com/documentation/cfnetwork/cfftpstream>.
// These are CFString constants used to configure FTP read/write streams
// (e.g. via `CFReadStreamSetProperty`). touchHLE does not implement real FTP
// networking, but exporting the constants keeps guest apps that merely
// reference these symbols (e.g. "PotaTossSocial", whose networking layer links
// against `kCFStreamPropertyFTPAttemptPersistentConnection`) from hitting an
// unresolved non-lazy symbol at load time.
pub const kCFStreamPropertyFTPUserName: &str = "kCFStreamPropertyFTPUserName";
pub const kCFStreamPropertyFTPPassword: &str = "kCFStreamPropertyFTPPassword";
pub const kCFStreamPropertyFTPUsePassiveMode: &str = "kCFStreamPropertyFTPUsePassiveMode";
pub const kCFStreamPropertyFTPResourceSize: &str = "kCFStreamPropertyFTPResourceSize";
pub const kCFStreamPropertyFTPFetchResourceInfo: &str = "kCFStreamPropertyFTPFetchResourceInfo";
pub const kCFStreamPropertyFTPFileTransferOffset: &str = "kCFStreamPropertyFTPFileTransferOffset";
pub const kCFStreamPropertyFTPAttemptPersistentConnection: &str =
    "kCFStreamPropertyFTPAttemptPersistentConnection";
pub const kCFStreamPropertyFTPProxy: &str = "kCFStreamPropertyFTPProxy";
pub const kCFStreamPropertyFTPProxyHost: &str = "kCFStreamPropertyFTPProxyHost";
pub const kCFStreamPropertyFTPProxyPort: &str = "kCFStreamPropertyFTPProxyPort";
pub const kCFStreamPropertyFTPProxyUser: &str = "kCFStreamPropertyFTPProxyUser";
pub const kCFStreamPropertyFTPProxyPassword: &str = "kCFStreamPropertyFTPProxyPassword";

pub const CONSTANTS: ConstantExports = &[
    (
        "_kCFStreamPropertyDataWritten",
        HostConstant::NSString(kCFStreamPropertyDataWritten),
    ),
    (
        "_kCFStreamPropertyAppendToFile",
        HostConstant::NSString(kCFStreamPropertyAppendToFile),
    ),
    (
        "_kCFStreamPropertyFileCurrentOffset",
        HostConstant::NSString(kCFStreamPropertyFileCurrentOffset),
    ),
    (
        "_kCFStreamPropertySocketNativeHandle",
        HostConstant::NSString(kCFStreamPropertySocketNativeHandle),
    ),
    (
        "_kCFStreamPropertySocketRemoteHostName",
        HostConstant::NSString(kCFStreamPropertySocketRemoteHostName),
    ),
    (
        "_kCFStreamPropertySocketRemotePortNumber",
        HostConstant::NSString(kCFStreamPropertySocketRemotePortNumber),
    ),
    (
        "_kCFStreamPropertySocketSecurityLevel",
        HostConstant::NSString(kCFStreamPropertySocketSecurityLevel),
    ),
    (
        "_kCFStreamPropertyShouldCloseNativeSocket",
        HostConstant::NSString(kCFStreamPropertyShouldCloseNativeSocket),
    ),
    (
        "_kCFStreamPropertySSLSettings",
        HostConstant::NSString(kCFStreamPropertySSLSettings),
    ),
    (
        "_kCFStreamSSLLevel",
        HostConstant::NSString(kCFStreamSSLLevel),
    ),
    (
        "_kCFStreamSSLAllowsExpiredCertificates",
        HostConstant::NSString(kCFStreamSSLAllowsExpiredCertificates),
    ),
    (
        "_kCFStreamSSLAllowsExpiredRoots",
        HostConstant::NSString(kCFStreamSSLAllowsExpiredRoots),
    ),
    (
        "_kCFStreamSSLAllowsAnyRoot",
        HostConstant::NSString(kCFStreamSSLAllowsAnyRoot),
    ),
    (
        "_kCFStreamSSLValidatesCertificateChain",
        HostConstant::NSString(kCFStreamSSLValidatesCertificateChain),
    ),
    (
        "_kCFStreamSSLPeerName",
        HostConstant::NSString(kCFStreamSSLPeerName),
    ),
    (
        "_kCFStreamSSLCertificates",
        HostConstant::NSString(kCFStreamSSLCertificates),
    ),
    (
        "_kCFStreamSSLIsServer",
        HostConstant::NSString(kCFStreamSSLIsServer),
    ),
    // Network service-type stream property + values.
    (
        "_kCFStreamNetworkServiceType",
        HostConstant::NSString("kCFStreamNetworkServiceType"),
    ),
    (
        "_kCFStreamNetworkServiceTypeVoIP",
        HostConstant::NSString("kCFStreamNetworkServiceTypeVoIP"),
    ),
    (
        "_kCFStreamNetworkServiceTypeVideo",
        HostConstant::NSString("kCFStreamNetworkServiceTypeVideo"),
    ),
    (
        "_kCFStreamNetworkServiceTypeBackground",
        HostConstant::NSString("kCFStreamNetworkServiceTypeBackground"),
    ),
    (
        "_kCFStreamNetworkServiceTypeVoice",
        HostConstant::NSString("kCFStreamNetworkServiceTypeVoice"),
    ),
    // Post-handshake SSL/TLS property keys.
    (
        "_kCFStreamPropertySSLPeerCertificates",
        HostConstant::NSString(kCFStreamPropertySSLPeerCertificates),
    ),
    (
        "_kCFStreamPropertySSLPeerTrust",
        HostConstant::NSString(kCFStreamPropertySSLPeerTrust),
    ),
    (
        "_kCFStreamPropertySSLContext",
        HostConstant::NSString(kCFStreamPropertySSLContext),
    ),
    // Socket security-level option values.
    (
        "_kCFStreamSocketSecurityLevelNone",
        HostConstant::NSString(kCFStreamSocketSecurityLevelNone),
    ),
    (
        "_kCFStreamSocketSecurityLevelSSLv2",
        HostConstant::NSString(kCFStreamSocketSecurityLevelSSLv2),
    ),
    (
        "_kCFStreamSocketSecurityLevelSSLv3",
        HostConstant::NSString(kCFStreamSocketSecurityLevelSSLv3),
    ),
    (
        "_kCFStreamSocketSecurityLevelTLSv1",
        HostConstant::NSString(kCFStreamSocketSecurityLevelTLSv1),
    ),
    (
        "_kCFStreamSocketSecurityLevelNegotiatedSSL",
        HostConstant::NSString(kCFStreamSocketSecurityLevelNegotiatedSSL),
    ),
    // CFFTPStream property keys.
    (
        "_kCFStreamPropertyFTPUserName",
        HostConstant::NSString(kCFStreamPropertyFTPUserName),
    ),
    (
        "_kCFStreamPropertyFTPPassword",
        HostConstant::NSString(kCFStreamPropertyFTPPassword),
    ),
    (
        "_kCFStreamPropertyFTPUsePassiveMode",
        HostConstant::NSString(kCFStreamPropertyFTPUsePassiveMode),
    ),
    (
        "_kCFStreamPropertyFTPResourceSize",
        HostConstant::NSString(kCFStreamPropertyFTPResourceSize),
    ),
    (
        "_kCFStreamPropertyFTPFetchResourceInfo",
        HostConstant::NSString(kCFStreamPropertyFTPFetchResourceInfo),
    ),
    (
        "_kCFStreamPropertyFTPFileTransferOffset",
        HostConstant::NSString(kCFStreamPropertyFTPFileTransferOffset),
    ),
    (
        "_kCFStreamPropertyFTPAttemptPersistentConnection",
        HostConstant::NSString(kCFStreamPropertyFTPAttemptPersistentConnection),
    ),
    (
        "_kCFStreamPropertyFTPProxy",
        HostConstant::NSString(kCFStreamPropertyFTPProxy),
    ),
    (
        "_kCFStreamPropertyFTPProxyHost",
        HostConstant::NSString(kCFStreamPropertyFTPProxyHost),
    ),
    (
        "_kCFStreamPropertyFTPProxyPort",
        HostConstant::NSString(kCFStreamPropertyFTPProxyPort),
    ),
    (
        "_kCFStreamPropertyFTPProxyUser",
        HostConstant::NSString(kCFStreamPropertyFTPProxyUser),
    ),
    (
        "_kCFStreamPropertyFTPProxyPassword",
        HostConstant::NSString(kCFStreamPropertyFTPProxyPassword),
    ),
];

// MARK: - ObjC backing classes

#[derive(Default)]
struct CFReadStreamHostObject {
    status: CFStreamStatus,
    offset: usize,
    data: Vec<u8>,
    /// Guest path, for streams made by [CFReadStreamCreateWithFile]. Real Core
    /// Foundation only touches the file when the stream is opened, so we keep
    /// the path here and open lazily.
    file_path: Option<String>,
    /// Live file descriptor, between `CFReadStreamOpen` and
    /// `CFReadStreamClose`/dealloc. Only ever set for file streams.
    fd: Option<posix_io::FileDescriptor>,
    /// Whether this stream came from [CFReadStreamCreateWithFile], even if no
    /// path could be taken from the URL. Streams made from bytes or a socket
    /// have nothing to open and are "open" on request; a file stream with no
    /// file must fail instead, or the caller waits forever for bytes that
    /// cannot arrive.
    is_file_stream: bool,
}
impl HostObject for CFReadStreamHostObject {}

#[derive(Default)]
struct CFWriteStreamHostObject {
    status: CFStreamStatus,
    data: Vec<u8>,
}
impl HostObject for CFWriteStreamHostObject {}

pub const CLASSES: ClassExports = objc_classes! {

(env, this, _cmd);

@implementation _touchHLE_CFReadStream: NSObject
- (())dealloc {
    // A stream that is released without CFReadStreamClose still owns its fd.
    let fd = env.objc.borrow_mut::<CFReadStreamHostObject>(this).fd.take();
    if let Some(fd) = fd {
        posix_io::close(env, fd);
    }
    env.objc.dealloc_object(this, &mut env.mem)
}
@end

@implementation _touchHLE_CFWriteStream: NSObject
- (())dealloc {
    env.objc.dealloc_object(this, &mut env.mem)
}
@end

};

// MARK: - Internal helpers

fn alloc_read_stream(env: &mut Environment) -> CFReadStreamRef {
    let class = env
        .objc
        .get_known_class("_touchHLE_CFReadStream", &mut env.mem);
    env.objc.alloc_object(
        class,
        Box::new(CFReadStreamHostObject {
            status: kCFStreamStatusNotOpen,
            offset: 0,
            data: Vec::new(),
            file_path: None,
            fd: None,
            is_file_stream: false,
        }),
        &mut env.mem,
    )
}

fn alloc_write_stream(env: &mut Environment) -> CFWriteStreamRef {
    let class = env
        .objc
        .get_known_class("_touchHLE_CFWriteStream", &mut env.mem);
    env.objc.alloc_object(
        class,
        Box::new(CFWriteStreamHostObject {
            status: kCFStreamStatusNotOpen,
            data: Vec::new(),
        }),
        &mut env.mem,
    )
}

// MARK: - Retain / Release

pub fn CFReadStreamRetain(env: &mut Environment, stream: CFReadStreamRef) -> CFReadStreamRef {
    if !stream.is_null() {
        CFRetain(env, stream)
    } else {
        stream
    }
}
pub fn CFReadStreamRelease(env: &mut Environment, stream: CFReadStreamRef) {
    if !stream.is_null() {
        CFRelease(env, stream);
    }
}
pub fn CFWriteStreamRetain(env: &mut Environment, stream: CFWriteStreamRef) -> CFWriteStreamRef {
    if !stream.is_null() {
        CFRetain(env, stream)
    } else {
        stream
    }
}
pub fn CFWriteStreamRelease(env: &mut Environment, stream: CFWriteStreamRef) {
    if !stream.is_null() {
        CFRelease(env, stream);
    }
}

// MARK: - Constructors

fn CFReadStreamCreateWithBytesNoCopy(
    env: &mut Environment,
    _allocator: CFAllocatorRef,
    _bytes: ConstPtr<u8>,
    _length: i32,
    _bytes_deallocator: CFAllocatorRef,
) -> CFReadStreamRef {
    log!("CFReadStreamCreateWithBytesNoCopy: stubbed");
    alloc_read_stream(env)
}

fn CFReadStreamCreateWithFile(
    env: &mut Environment,
    _allocator: CFAllocatorRef,
    file_url: CFTypeRef, // CFURLRef
) -> CFReadStreamRef {
    let path = if file_url.is_null() {
        None
    } else {
        let path: id = msg![env; file_url path];
        if path.is_null() {
            None
        } else {
            Some(ns_string::to_rust_string(env, path).into_owned())
        }
    };
    if path.is_none() {
        // Only once: a guest that gets a null URL here is being handed one by
        // a failed `CFBundleCopyResourceURL`, and Gamevil's WIPI loader retries
        // that hundreds of times a second. `CFBundleCopyResourceURL` names the
        // resource it could not find, which is the part worth reading.
        log_once!(
            "CFReadStreamCreateWithFile: no file path for URL {:?}; \
             the stream will fail to open.",
            file_url
        );
    }
    log_dbg!("CFReadStreamCreateWithFile({:?})", path);
    let stream = alloc_read_stream(env);
    let host = env.objc.borrow_mut::<CFReadStreamHostObject>(stream);
    host.file_path = path;
    host.is_file_stream = true;
    stream
}

fn CFWriteStreamCreateWithFile(
    env: &mut Environment,
    _allocator: CFAllocatorRef,
    _file_url: CFTypeRef, // CFURLRef
) -> CFWriteStreamRef {
    log_dbg!("CFWriteStreamCreateWithFile: stubbed");
    alloc_write_stream(env)
}

fn CFWriteStreamCreateWithAllocatedBuffers(
    env: &mut Environment,
    _allocator: CFAllocatorRef,
    _buffer_allocator: CFAllocatorRef,
) -> CFWriteStreamRef {
    log!("CFWriteStreamCreateWithAllocatedBuffers: stubbed");
    alloc_write_stream(env)
}

fn CFStreamCreatePairWithSocket(
    env: &mut Environment,
    _allocator: CFAllocatorRef,
    _sock: i32, // CFSocketNativeHandle
    read_stream: MutPtr<CFReadStreamRef>,
    write_stream: MutPtr<CFWriteStreamRef>,
) {
    log!("CFStreamCreatePairWithSocket: stubbed — streams set to null");
    if !read_stream.is_null() {
        env.mem.write(read_stream, nil);
    }
    if !write_stream.is_null() {
        env.mem.write(write_stream, nil);
    }
}

fn CFStreamCreatePairWithPeerSocketSignature(
    env: &mut Environment,
    _allocator: CFAllocatorRef,
    _signature: crate::mem::ConstVoidPtr,
    read_stream: MutPtr<CFReadStreamRef>,
    write_stream: MutPtr<CFWriteStreamRef>,
) {
    log!("CFStreamCreatePairWithPeerSocketSignature: stubbed — streams set to null");
    if !read_stream.is_null() {
        env.mem.write(read_stream, nil);
    }
    if !write_stream.is_null() {
        env.mem.write(write_stream, nil);
    }
}

fn CFStreamCreatePairWithSocketToHost(
    env: &mut Environment,
    _allocator: CFAllocatorRef,
    host: CFStringRef,
    port: u32,
    read_stream: MutPtr<CFReadStreamRef>,
    write_stream: MutPtr<CFWriteStreamRef>,
) {
    let host_str = if host.is_null() {
        "<nil>".to_string()
    } else {
        ns_string::to_rust_string(env, host).into_owned()
    };
    log!(
        "CFStreamCreatePairWithSocketToHost: {}:{} — stubbed, returning dummy streams",
        host_str,
        port
    );
    // Return valid (but non-functional) stream objects rather than NULL.
    // Many apps do not nil-check the returned streams before calling
    // CFReadStreamOpen / CFReadStreamSetProperty etc. Returning NULL causes
    // the ObjC runtime to hit the phantom-object fallback path and produce
    // "SUPER HACK! Faking borrow_mut" warnings. A stub stream that
    // immediately reports "at end" (for reads) or "closed" (for writes)
    // after open is a safer contract.
    if !read_stream.is_null() {
        let rs = alloc_read_stream(env);
        env.mem.write(read_stream, rs);
    }
    if !write_stream.is_null() {
        let ws = alloc_write_stream(env);
        env.mem.write(write_stream, ws);
    }
}

// MARK: - Open / Close

fn CFReadStreamOpen(env: &mut Environment, stream: CFReadStreamRef) -> bool {
    if stream.is_null() {
        return false;
    }
    let (file_path, already_open, is_file_stream) = {
        let host = env.objc.borrow::<CFReadStreamHostObject>(stream);
        (
            host.file_path.clone(),
            host.fd.is_some(),
            host.is_file_stream,
        )
    };
    let Some(file_path) = file_path else {
        let host = env.objc.borrow_mut::<CFReadStreamHostObject>(stream);
        if is_file_stream {
            // Made from a URL that had no usable path, so there is no file to
            // open. Reporting success here gives the caller a stream that is
            // "open" and will never yield a byte: Gamevil's WIPI loader spins
            // on exactly that, hundreds of times a second, instead of taking
            // the error path it already has for a stream that fails to open.
            log_once!(
                "CFReadStreamOpen: stream has no file behind it (the URL had no \
                 path); reporting failure so the caller can give up."
            );
            host.status = kCFStreamStatusError;
            return false;
        }
        // Streams made from bytes or a socket have nothing to open, and are
        // open as soon as they are asked to be.
        host.status = kCFStreamStatusOpen;
        host.offset = 0;
        return true;
    };
    if already_open {
        // Opening twice is a guest error; don't leak the first descriptor.
        return true;
    }
    let path_cstr = env.mem.alloc_and_write_cstr(file_path.as_bytes());
    let fd = posix_io::open_direct(env, path_cstr.cast_const(), posix_io::O_RDONLY);
    env.mem.free(path_cstr.cast());
    if fd != -1 && posix_io::is_directory_fd(env, fd) {
        // `open()` on a directory succeeds — it is the `read()` that fails
        // with EISDIR — so without this check the stream reports itself open
        // and then fails every single read, forever.
        log!(
            "CFReadStreamOpen: {:?} is a directory, not a file; reporting failure.",
            file_path
        );
        posix_io::close(env, fd);
        env.objc.borrow_mut::<CFReadStreamHostObject>(stream).status = kCFStreamStatusError;
        return false;
    }
    let host = env.objc.borrow_mut::<CFReadStreamHostObject>(stream);
    if fd == -1 {
        log!("CFReadStreamOpen: could not open {:?}", file_path);
        host.status = kCFStreamStatusError;
        return false;
    }
    log_dbg!("CFReadStreamOpen({:?}) => fd {}", file_path, fd);
    host.fd = Some(fd);
    host.status = kCFStreamStatusOpen;
    true
}

fn CFReadStreamClose(env: &mut Environment, stream: CFReadStreamRef) {
    if stream.is_null() {
        return;
    }
    let fd = env.objc.borrow_mut::<CFReadStreamHostObject>(stream).fd.take();
    if let Some(fd) = fd {
        posix_io::close(env, fd);
    }
    env.objc.borrow_mut::<CFReadStreamHostObject>(stream).status = kCFStreamStatusClosed;
}

fn CFWriteStreamOpen(env: &mut Environment, stream: CFWriteStreamRef) -> bool {
    if stream.is_null() {
        return false;
    }
    env.objc
        .borrow_mut::<CFWriteStreamHostObject>(stream)
        .status = kCFStreamStatusOpen;
    true
}

fn CFWriteStreamClose(env: &mut Environment, stream: CFWriteStreamRef) {
    if stream.is_null() {
        return;
    }
    log_dbg!("CFWriteStreamClose: stubbed");
    env.objc
        .borrow_mut::<CFWriteStreamHostObject>(stream)
        .status = kCFStreamStatusClosed;
}

// MARK: - Status

fn CFReadStreamGetStatus(env: &mut Environment, stream: CFReadStreamRef) -> CFStreamStatus {
    if stream.is_null() {
        return kCFStreamStatusError;
    }
    env.objc.borrow::<CFReadStreamHostObject>(stream).status
}

fn CFWriteStreamGetStatus(env: &mut Environment, stream: CFWriteStreamRef) -> CFStreamStatus {
    if stream.is_null() {
        return kCFStreamStatusError;
    }
    env.objc.borrow::<CFWriteStreamHostObject>(stream).status
}

fn CFReadStreamGetError(_env: &mut Environment, _stream: CFReadStreamRef) -> u64 {
    // CFStreamError (two i32 fields packed)
    // domain=kCFStreamErrorDomainCustom, error=-1
    ((kCFStreamErrorDomainCustom as u64) & 0xFFFF_FFFF) | ((-1i32 as u32 as u64) << 32)
}

fn CFWriteStreamGetError(_env: &mut Environment, _stream: CFWriteStreamRef) -> u64 {
    ((kCFStreamErrorDomainCustom as u64) & 0xFFFF_FFFF) | ((-1i32 as u32 as u64) << 32)
}

// MARK: - Read / Write

fn CFReadStreamRead(
    env: &mut Environment,
    stream: CFReadStreamRef,
    buffer: MutPtr<u8>,
    buffer_length: i32,
) -> i32 {
    if stream.is_null() || buffer.is_null() || buffer_length < 0 {
        return -1;
    }
    let (is_file, fd, status) = {
        let host = env.objc.borrow::<CFReadStreamHostObject>(stream);
        (host.file_path.is_some(), host.fd, host.status)
    };
    if is_file {
        let Some(fd) = fd else {
            env.objc.borrow_mut::<CFReadStreamHostObject>(stream).status = kCFStreamStatusError;
            return -1;
        };
        // Reading at EOF is legal and returns 0, so kCFStreamStatusAtEnd is
        // not an error here.
        if status != kCFStreamStatusOpen
            && status != kCFStreamStatusReading
            && status != kCFStreamStatusAtEnd
        {
            return -1;
        }
        env.objc.borrow_mut::<CFReadStreamHostObject>(stream).status = kCFStreamStatusReading;
        let bytes_read = posix_io::read(env, fd, buffer.cast(), buffer_length as u32);
        let host = env.objc.borrow_mut::<CFReadStreamHostObject>(stream);
        if bytes_read == 0 {
            host.status = kCFStreamStatusAtEnd;
        } else if bytes_read < 0 {
            host.status = kCFStreamStatusError;
        }
        return bytes_read;
    }
    let host = env.objc.borrow_mut::<CFReadStreamHostObject>(stream);
    if status != kCFStreamStatusOpen && status != kCFStreamStatusReading {
        return -1;
    }
    let remaining = host.data.len().saturating_sub(host.offset);
    let copy_len = remaining.min(buffer_length as usize);
    if copy_len > 0 {
        env.mem
            .bytes_at_mut(buffer, copy_len as u32)
            .copy_from_slice(&host.data[host.offset..host.offset + copy_len]);
        host.offset += copy_len;
    }
    if host.offset >= host.data.len() {
        host.status = kCFStreamStatusAtEnd;
    }
    copy_len as i32
}

fn CFReadStreamGetBuffer(
    _env: &mut Environment,
    _stream: CFReadStreamRef,
    _max_bytes_to_read: i32,
    _num_bytes_read: MutPtr<i32>,
) -> ConstPtr<u8> {
    ConstPtr::null()
}

fn CFReadStreamHasBytesAvailable(env: &mut Environment, stream: CFReadStreamRef) -> bool {
    if stream.is_null() {
        return false;
    }
    let (is_file, fd, status, offset, len) = {
        let host = env.objc.borrow::<CFReadStreamHostObject>(stream);
        (
            host.file_path.is_some(),
            host.fd,
            host.status,
            host.offset,
            host.data.len(),
        )
    };
    if is_file {
        let Some(fd) = fd else {
            return false;
        };
        if status == kCFStreamStatusAtEnd {
            return false;
        }
        let current = posix_io::lseek(env, fd, 0, posix_io::SEEK_CUR);
        if current == -1 {
            return false;
        }
        let end = posix_io::lseek(env, fd, 0, posix_io::SEEK_END);
        if end == -1 {
            return false;
        }
        posix_io::lseek(env, fd, current, posix_io::SEEK_SET);
        return end > current;
    }
    offset < len
}

fn CFWriteStreamWrite(
    env: &mut Environment,
    stream: CFWriteStreamRef,
    buffer: ConstPtr<u8>,
    buffer_length: i32,
) -> i32 {
    if stream.is_null() || buffer.is_null() || buffer_length < 0 {
        return -1;
    }
    let host = env.objc.borrow_mut::<CFWriteStreamHostObject>(stream);
    if host.status != kCFStreamStatusOpen && host.status != kCFStreamStatusWriting {
        return -1;
    }
    let bytes = env.mem.bytes_at(buffer, buffer_length as u32);
    host.data.extend_from_slice(bytes);
    buffer_length
}

fn CFWriteStreamCanAcceptBytes(env: &mut Environment, stream: CFWriteStreamRef) -> bool {
    if stream.is_null() {
        return false;
    }
    let status = env.objc.borrow::<CFWriteStreamHostObject>(stream).status;
    status == kCFStreamStatusOpen || status == kCFStreamStatusWriting
}

// MARK: - Properties

fn CFReadStreamCopyProperty(
    _env: &mut Environment,
    _stream: CFReadStreamRef,
    _property_name: CFStringRef,
) -> CFTypeRef {
    nil
}

fn CFReadStreamSetProperty(
    _env: &mut Environment,
    _stream: CFReadStreamRef,
    _property_name: CFStringRef,
    _property_value: CFTypeRef,
) -> bool {
    log_dbg!("CFReadStreamSetProperty: stubbed -> false");
    false
}

fn CFWriteStreamCopyProperty(
    _env: &mut Environment,
    _stream: CFWriteStreamRef,
    _property_name: CFStringRef,
) -> CFTypeRef {
    nil
}

fn CFWriteStreamSetProperty(
    _env: &mut Environment,
    _stream: CFWriteStreamRef,
    _property_name: CFStringRef,
    _property_value: CFTypeRef,
) -> bool {
    log_dbg!("CFWriteStreamSetProperty: stubbed -> false");
    false
}

// MARK: - Client / Run loop scheduling

fn CFReadStreamSetClient(
    _env: &mut Environment,
    _stream: CFReadStreamRef,
    _stream_events: CFStreamEventType,
    _client_cb: MutVoidPtr,
    _client_ctx: MutVoidPtr,
) -> bool {
    true
}

fn CFWriteStreamSetClient(
    _env: &mut Environment,
    _stream: CFWriteStreamRef,
    _stream_events: CFStreamEventType,
    _client_cb: MutVoidPtr,
    _client_ctx: MutVoidPtr,
) -> bool {
    true
}

fn CFReadStreamScheduleWithRunLoop(
    _env: &mut Environment,
    _stream: CFReadStreamRef,
    _run_loop: CFTypeRef,
    _run_loop_mode: CFStringRef,
) {
    log_dbg!("CFReadStreamScheduleWithRunLoop: stubbed");
}

fn CFReadStreamUnscheduleFromRunLoop(
    _env: &mut Environment,
    _stream: CFReadStreamRef,
    _run_loop: CFTypeRef,
    _run_loop_mode: CFStringRef,
) {
    log_dbg!("CFReadStreamUnscheduleFromRunLoop: stubbed");
}

fn CFWriteStreamScheduleWithRunLoop(
    _env: &mut Environment,
    _stream: CFWriteStreamRef,
    _run_loop: CFTypeRef,
    _run_loop_mode: CFStringRef,
) {
    log_dbg!("CFWriteStreamScheduleWithRunLoop: stubbed");
}

fn CFWriteStreamUnscheduleFromRunLoop(
    _env: &mut Environment,
    _stream: CFWriteStreamRef,
    _run_loop: CFTypeRef,
    _run_loop_mode: CFStringRef,
) {
    log_dbg!("CFWriteStreamUnscheduleFromRunLoop: stubbed");
}

fn CFStreamCreatePairWithSocketToCFHost(
    env: &mut Environment,
    _allocator: CFAllocatorRef,
    host: CFTypeRef,
    port: i32,
    read_stream: MutPtr<CFReadStreamRef>,
    write_stream: MutPtr<CFWriteStreamRef>,
) {
    let host_str = if !host.is_null() {
        env.objc
            .borrow::<crate::frameworks::core_foundation::cf_host::CFHostHostObject>(host)
            .name
            .clone()
            .unwrap_or_else(|| "<address>".to_string())
    } else {
        "<nil>".to_string()
    };

    log!(
        "CFStreamCreatePairWithSocketToCFHost: host={} port={} — stubbed, returning dummy streams",
        host_str,
        port
    );

    if !read_stream.is_null() {
        let rs = alloc_read_stream(env);
        env.mem.write(read_stream, rs);
    }
    if !write_stream.is_null() {
        let ws = alloc_write_stream(env);
        env.mem.write(write_stream, ws);
    }
}

pub const FUNCTIONS: FunctionExports = &[
    // Retain / Release
    export_c_func!(CFReadStreamRetain(_)),
    export_c_func!(CFReadStreamRelease(_)),
    export_c_func!(CFWriteStreamRetain(_)),
    export_c_func!(CFWriteStreamRelease(_)),
    // Constructors
    export_c_func!(CFReadStreamCreateWithBytesNoCopy(_, _, _, _)),
    export_c_func!(CFReadStreamCreateWithFile(_, _)),
    export_c_func!(CFWriteStreamCreateWithFile(_, _)),
    export_c_func!(CFWriteStreamCreateWithAllocatedBuffers(_, _)),
    export_c_func!(CFStreamCreatePairWithSocket(_, _, _, _)),
    export_c_func!(CFStreamCreatePairWithPeerSocketSignature(_, _, _, _)),
    export_c_func!(CFStreamCreatePairWithSocketToHost(_, _, _, _, _)),
    // Open / Close
    export_c_func!(CFReadStreamOpen(_)),
    export_c_func!(CFReadStreamClose(_)),
    export_c_func!(CFWriteStreamOpen(_)),
    export_c_func!(CFWriteStreamClose(_)),
    // Status
    export_c_func!(CFReadStreamGetStatus(_)),
    export_c_func!(CFWriteStreamGetStatus(_)),
    export_c_func!(CFReadStreamGetError(_)),
    export_c_func!(CFWriteStreamGetError(_)),
    // Read
    export_c_func!(CFReadStreamRead(_, _, _)),
    export_c_func!(CFReadStreamGetBuffer(_, _, _)),
    export_c_func!(CFReadStreamHasBytesAvailable(_)),
    // Write
    export_c_func!(CFWriteStreamWrite(_, _, _)),
    export_c_func!(CFWriteStreamCanAcceptBytes(_)),
    // Properties
    export_c_func!(CFReadStreamCopyProperty(_, _)),
    export_c_func!(CFReadStreamSetProperty(_, _, _)),
    export_c_func!(CFWriteStreamCopyProperty(_, _)),
    export_c_func!(CFWriteStreamSetProperty(_, _, _)),
    // Client / run loop
    export_c_func!(CFReadStreamSetClient(_, _, _, _)),
    export_c_func!(CFWriteStreamSetClient(_, _, _, _)),
    export_c_func!(CFReadStreamScheduleWithRunLoop(_, _, _)),
    export_c_func!(CFReadStreamUnscheduleFromRunLoop(_, _, _)),
    export_c_func!(CFWriteStreamScheduleWithRunLoop(_, _, _)),
    export_c_func!(CFWriteStreamUnscheduleFromRunLoop(_, _, _)),
    export_c_func!(CFStreamCreatePairWithSocketToCFHost(_, _, _, _, _)),
];
