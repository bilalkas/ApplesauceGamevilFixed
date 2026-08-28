pub fn CFURLGetFileSystemRepresentation(
    env: &mut Environment,
    url: CFURLRef,
    resolve_against_base: bool,
    buffer: MutPtr<u8>,
    buffer_size: CFIndex,
) -> bool {
    if url.is_null() || buffer.is_null() || buffer_size <= 0 {
        return false;
    }

    let actual_url = if resolve_against_base {
        let absolute_url: id = msg![env; url absoluteURL];
        if !absolute_url.is_null() {
            absolute_url
        } else {
            url
        }
    } else {
        url
    };

    let path: id = msg![env; actual_url path];
    if path.is_null() {
        return false;
    }

    // Sichere Rust-String-Extraktion ohne "cstr_at_utf8"
    let path_str = crate::frameworks::foundation::ns_string::to_rust_string(env, path);
    let bytes = path_str.as_bytes();
    let buffer_size_usize = buffer_size as usize;

    if bytes.len() >= buffer_size_usize {
        return false; // Buffer zu klein für String + Null-Terminator
    }

    for (i, &b) in bytes.iter().enumerate() {
        env.mem.write(buffer + (i as u32), b);
    }
    env.mem.write(buffer + (bytes.len() as u32), 0); // Null-Terminator

    true
}
