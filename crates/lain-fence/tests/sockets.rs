//! The fence's seccomp filter against every socket but Unix, netlink and
//! plain TCP, against TCP Fast Open, and against io_uring, run for real on
//! this kernel.
//!
//! Python creates the sockets because it passes family, type and protocol
//! straight to socket(2), adding `SOCK_CLOEXEC` to the type, which is the flag
//! the filter must mask off. Its ctypes makes the raw io_uring and x32 calls.
#![cfg(target_os = "linux")]

pub mod common;

use common::{FENCE, cannot_run, refused_with, skipped};
use std::io::ErrorKind;
use std::net::{TcpListener, UdpSocket};
use std::process::{Command, Output};
use std::time::Duration;

const GRANTS: [&str; 5] = ["--read-dir", "/", "--exec-dir", "/usr", "--"];
const EPERM: &str = "1";
const ENOSYS: &str = "38";

/// Exit 3 marks a refusal; the errno follows "refused".
const PROBE: &str = r#"
import ctypes, socket, struct, sys
kind, arg = sys.argv[1], sys.argv[2]
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
X32 = 0x40000000

def raw(number, *args):
    if libc.syscall(ctypes.c_long(number), *args) < 0:
        return ctypes.get_errno()
    return 0

def open_socket(family, kind, proto=0):
    try:
        socket.socket(family, kind, proto).close()
        return 0
    except OSError as e:
        return e.errno

def udp_send():
    try:
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"probe", ("127.0.0.1", int(arg)))
        return 0
    except OSError as e:
        return e.errno

MSG_FASTOPEN = 0x20000000

def loopback(port):
    return ("127.0.0.1", int(port))

def sendmmsg_fastopen(fd, port):
    name = ctypes.create_string_buffer(
        struct.pack("=H", socket.AF_INET) + struct.pack("!H", int(port))
        + socket.inet_aton("127.0.0.1") + bytes(8), 16)
    data = ctypes.create_string_buffer(b"probe", 5)
    iov = ctypes.create_string_buffer(struct.pack("=QQ", ctypes.addressof(data), 5), 16)
    header = struct.pack("=QI4xQQQQi4xI4x", ctypes.addressof(name), 16, ctypes.addressof(iov), 1, 0, 0, 0, 0)
    mmsg = ctypes.create_string_buffer(header, 64)
    return raw(307, fd, mmsg, 1, MSG_FASTOPEN)

def fast_open(how):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        if how == "sendto":
            s.sendto(b"probe", MSG_FASTOPEN, loopback(arg))
        elif how == "sendmsg":
            s.sendmsg([b"probe"], [], MSG_FASTOPEN, loopback(arg))
        else:
            return sendmmsg_fastopen(s.fileno(), arg)
        return 0
    except OSError as e:
        return e.errno

def x32_fast_open(number, *args):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    return raw(number | X32, s.fileno(), *args)

def tcp_option(option, number=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if number is not None:
        one = ctypes.c_int(1)
        return raw(number | X32, s.fileno(), 6, option, ctypes.byref(one), 4)
    try:
        s.setsockopt(socket.IPPROTO_TCP, option, 1)
        return 0
    except OSError as e:
        return e.errno

params = ctypes.create_string_buffer(120)
probes = {
    "udp4_send": udp_send,
    "udp6": lambda: open_socket(socket.AF_INET6, socket.SOCK_DGRAM),
    "ping": lambda: open_socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP),
    "raw": lambda: open_socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP),
    "sctp": lambda: open_socket(socket.AF_INET, socket.SOCK_STREAM, 132),
    "sctp_seqpacket": lambda: open_socket(socket.AF_INET6, socket.SOCK_SEQPACKET, 132),
    "mptcp": lambda: open_socket(socket.AF_INET, socket.SOCK_STREAM, 262),
    "smc_protocol": lambda: open_socket(socket.AF_INET, socket.SOCK_STREAM, 256),
    "inet_seqpacket": lambda: open_socket(socket.AF_INET, socket.SOCK_SEQPACKET, 0),
    "af_smc": lambda: open_socket(43, socket.SOCK_STREAM, 0),
    "af_vsock": lambda: open_socket(40, socket.SOCK_STREAM, 0),
    "af_alg": lambda: open_socket(38, socket.SOCK_SEQPACKET, 0),
    "tfo_sendto": lambda: fast_open("sendto"),
    "tfo_sendmsg": lambda: fast_open("sendmsg"),
    "tfo_sendmmsg": lambda: fast_open("sendmmsg"),
    "fastopen_connect_option": lambda: tcp_option(30),
    "nodelay_option": lambda: tcp_option(1),
    "x32_fastopen_connect_option": lambda: tcp_option(30, 541),
    "x32_tfo_sendto": lambda: x32_fast_open(44, None, 0, MSG_FASTOPEN, None, 0),
    "x32_tfo_sendmsg": lambda: x32_fast_open(518, None, MSG_FASTOPEN),
    "x32_tfo_sendmmsg": lambda: x32_fast_open(538, None, 1, MSG_FASTOPEN),
    "tcp": lambda: open_socket(socket.AF_INET, socket.SOCK_STREAM),
    "unix": lambda: open_socket(socket.AF_UNIX, socket.SOCK_STREAM),
    "netlink": lambda: open_socket(socket.AF_NETLINK, socket.SOCK_RAW, 0),
    "io_uring": lambda: raw(425, ctypes.c_uint(1), params),
    "x32_socket": lambda: raw(41 | X32, 2, 2, 0),
    "x32_io_uring": lambda: raw(425 | X32, ctypes.c_uint(1), params),
}
err = probes[kind]()
if err:
    print("refused", err)
    sys.exit(3)
print("created")
"#;

fn probe(fenced: bool, kind: &str, arg: &str) -> Output {
    let python = ["python3", "-I", "-c", PROBE, kind, arg];
    let mut command = Command::new("timeout");
    command.arg("20");
    if fenced {
        command.arg(FENCE).args(GRANTS);
    }
    command
        .args(python)
        .env("LC_ALL", "C")
        .output()
        .expect("spawn probe")
}

fn fenced(kind: &str) -> Output {
    probe(true, kind, "0")
}

fn assert_refused(kind: &str) {
    let out = fenced(kind);
    assert_eq!(
        refused_with(&out).as_deref(),
        Some(EPERM),
        "{kind}: {out:?}"
    );
    assert_eq!(out.status.code(), Some(3), "{kind}: {out:?}");
}

#[test]
fn a_udp_send_to_a_loopback_listener_is_refused() {
    if cannot_run("udp send") {
        return;
    }
    let listener = UdpSocket::bind("127.0.0.1:0").expect("bind");
    listener
        .set_read_timeout(Some(Duration::from_millis(300)))
        .expect("read timeout");
    let port = listener.local_addr().expect("addr").port().to_string();

    let out = probe(true, "udp4_send", &port);

    assert_eq!(refused_with(&out).as_deref(), Some(EPERM), "{out:?}");
    let mut buffer = [0u8; 16];
    let received = listener.recv_from(&mut buffer);
    assert!(
        matches!(&received, Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut)),
        "the listener got {received:?}"
    );
}

#[test]
fn ipv6_udp_ping_raw_and_sctp_sockets_are_refused() {
    if cannot_run("datagram, raw and sctp sockets") {
        return;
    }

    for kind in ["udp6", "ping", "raw", "sctp", "sctp_seqpacket"] {
        assert_refused(kind);
    }
}

#[test]
fn an_inet_socket_other_than_plain_tcp_is_refused() {
    if cannot_run("smc and seqpacket inet sockets") {
        return;
    }

    for kind in ["smc_protocol", "inet_seqpacket"] {
        assert_refused(kind);
    }
}

#[test]
fn every_family_but_unix_inet_and_netlink_is_refused() {
    if cannot_run("other socket families") {
        return;
    }

    for kind in ["af_smc", "af_vsock", "af_alg"] {
        assert_refused(kind);
    }
}

/// Polled a bounded number of times, so a refusal costs half a second at most.
fn accepted_any(listener: &TcpListener) -> bool {
    (0..5).any(|_| {
        let accepted = listener.accept().is_ok();
        if !accepted {
            std::thread::sleep(Duration::from_millis(100));
        }
        accepted
    })
}

#[test]
fn tcp_fast_open_cannot_reach_a_port_no_grant_names() {
    if cannot_run("tcp fast open") {
        return;
    }

    for kind in ["tfo_sendto", "tfo_sendmsg", "tfo_sendmmsg"] {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        listener.set_nonblocking(true).expect("nonblocking");
        let port = listener.local_addr().expect("addr").port().to_string();

        let out = probe(true, kind, &port);

        assert_eq!(
            refused_with(&out).as_deref(),
            Some(EPERM),
            "{kind}: {out:?}"
        );
        assert!(
            !accepted_any(&listener),
            "{kind} reached the listener: {out:?}"
        );
    }
}

#[test]
fn a_deferred_fast_open_connect_cannot_be_armed() {
    if cannot_run("fast open connect option") {
        return;
    }

    assert_refused("fastopen_connect_option");
    let nodelay = fenced("nodelay_option");
    assert_eq!(
        String::from_utf8_lossy(&nodelay.stdout),
        "created\n",
        "{nodelay:?}"
    );
}

#[test]
fn an_mptcp_socket_is_refused() {
    if cannot_run("mptcp socket") {
        return;
    }

    assert_refused("mptcp");
}

#[test]
fn tcp_unix_and_netlink_sockets_still_open() {
    if cannot_run("stream, unix and netlink sockets") {
        return;
    }

    for kind in ["tcp", "unix", "netlink"] {
        let out = fenced(kind);
        assert_eq!(
            String::from_utf8_lossy(&out.stdout),
            "created\n",
            "{kind}: {out:?}"
        );
        assert!(out.status.success(), "{kind}: {out:?}");
    }
}

#[test]
fn io_uring_cannot_be_set_up() {
    if cannot_run("io_uring") {
        return;
    }

    assert_refused("io_uring");
}

#[cfg(target_arch = "x86_64")]
#[test]
fn the_x32_numbers_are_refused_too() {
    if cannot_run("x32 socket and io_uring") {
        return;
    }
    if refused_with(&probe(false, "x32_socket", "0")).as_deref() == Some(ENOSYS) {
        skipped("x32 socket and io_uring", "this kernel has no x32 ABI");
        return;
    }

    for kind in [
        "x32_socket",
        "x32_io_uring",
        "x32_tfo_sendto",
        "x32_tfo_sendmsg",
        "x32_tfo_sendmmsg",
        "x32_fastopen_connect_option",
    ] {
        assert_refused(kind);
    }
}

#[test]
fn status_names_the_socket_and_io_uring_verdicts() {
    if cannot_run("status verdicts") {
        return;
    }
    let out = Command::new("timeout")
        .args(["20", FENCE, "--status", "--exec-dir", "/usr"])
        .output()
        .expect("spawn fence");
    assert!(out.status.success(), "fence --status failed: {out:?}");
    let report: serde_json::Value = serde_json::from_slice(&out.stdout).expect("status is JSON");

    for name in ["memfd_noexec", "inet_socket_types", "io_uring"] {
        assert_eq!(report["rights"][name], "enforced", "{name} in {report}");
    }
}
