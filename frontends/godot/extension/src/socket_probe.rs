//! Diagnostic for remote WebSocket sockets (GRAFFITTY_SOCKET_TRACE=1): lists
//! this process's TCP sockets with their peer, TCP_NODELAY state, and the
//! errno of setting TCP_NODELAY, to stderr. Godot warns "Unable to set TCP no
//! delay option." without saying why.

use godot::prelude::*;

#[derive(GodotClass)]
#[class(base=RefCounted, init)]
struct SocketProbe;

#[godot_api]
impl SocketProbe {
    #[func]
    fn enabled() -> bool {
        std::env::var_os("GRAFFITTY_SOCKET_TRACE").is_some()
    }

    #[func]
    fn report(label: GString) {
        if !Self::enabled() {
            return;
        }
        eprintln!("[gft-socket] {label}");
        #[cfg(unix)]
        for fd in 0..4096 {
            if let Some(line) = describe(fd) {
                eprintln!("[gft-socket]   {line}");
            }
        }
    }
}

/// Env-gated diagnostics to stderr, which the iOS device console shows
/// (Godot's own print does not reach it).
#[derive(GodotClass)]
#[class(base=RefCounted, init)]
struct DebugTrace;

#[godot_api]
impl DebugTrace {
    #[func]
    fn enabled(variable: GString) -> bool {
        std::env::var_os(variable.to_string()).is_some()
    }

    #[func]
    fn log(text: GString) {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        eprintln!("[gft-trace] {:.3} {text}", now.as_secs_f64());
    }
}

#[cfg(unix)]
fn describe(fd: i32) -> Option<String> {
    use std::mem::{size_of, zeroed};
    // SAFETY: getsockopt/getpeername/setsockopt on an fd number this process
    // may or may not own; failures are returned, nothing is closed.
    unsafe {
        let mut kind: libc::c_int = 0;
        let mut len = size_of::<libc::c_int>() as libc::socklen_t;
        if libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_TYPE, (&mut kind as *mut libc::c_int).cast(), &mut len) != 0
            || kind != libc::SOCK_STREAM
        {
            return None;
        }
        let mut peer: libc::sockaddr_storage = zeroed();
        let mut plen = size_of::<libc::sockaddr_storage>() as libc::socklen_t;
        let connected = libc::getpeername(fd, (&mut peer as *mut libc::sockaddr_storage).cast(), &mut plen) == 0;
        let peer_errno = if connected { 0 } else { std::io::Error::last_os_error().raw_os_error().unwrap_or(0) };
        let family = peer.ss_family as libc::c_int;
        if connected && family != libc::AF_INET && family != libc::AF_INET6 {
            return None;
        }
        let address = if !connected {
            format!("unconnected (getpeername errno {peer_errno})")
        } else if family == libc::AF_INET {
            let v4: libc::sockaddr_in = *(&peer as *const libc::sockaddr_storage).cast();
            let ip = std::net::Ipv4Addr::from(u32::from_be(v4.sin_addr.s_addr));
            format!("{ip}:{}", u16::from_be(v4.sin_port))
        } else {
            let v6: libc::sockaddr_in6 = *(&peer as *const libc::sockaddr_storage).cast();
            let ip = std::net::Ipv6Addr::from(v6.sin6_addr.s6_addr);
            format!("[{ip}]:{}", u16::from_be(v6.sin6_port))
        };
        let mut before: libc::c_int = 0;
        let mut blen = size_of::<libc::c_int>() as libc::socklen_t;
        let read = libc::getsockopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, (&mut before as *mut libc::c_int).cast(), &mut blen);
        let read_errno = if read != 0 { std::io::Error::last_os_error().raw_os_error().unwrap_or(0) } else { 0 };
        let one: libc::c_int = 1;
        let set = libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, (&one as *const libc::c_int).cast(), size_of::<libc::c_int>() as libc::socklen_t);
        let set_errno = if set != 0 { std::io::Error::last_os_error().raw_os_error().unwrap_or(0) } else { 0 };
        let mut soerr: libc::c_int = 0;
        let mut elen = size_of::<libc::c_int>() as libc::socklen_t;
        libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_ERROR, (&mut soerr as *mut libc::c_int).cast(), &mut elen);
        Some(format!(
            "fd={fd} peer={address} nodelay_before={before} (read errno {read_errno}) set_errno={set_errno} so_error={soerr}"
        ))
    }
}
