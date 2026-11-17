//! The notice an item that has waited too long becomes: a title and a link, nothing else.
//!
//! The topic is, to ntfy, a shared name, so neither an item's text nor its project or session may
//! reach it. The link carries the phone's id for the item, which only an app holding a paired token
//! can use.

use std::time::Duration;

use crate::agenda_watch::Notify;
use crate::relay::{Kind, Opened, REQUESTER_CHARS};

/// A dead topic must cost the daemon 1 failed notice, not a stuck task.
const TIMEOUT: Duration = Duration::from_secs(5);

const BODY: &str = "Open lain to answer.";

/// An ntfy topic, `http(s)://host:port/topic`.
pub(crate) struct Ntfy {
    url: String,
    timeout: Duration,
}

impl Ntfy {
    pub(crate) fn new(url: String) -> Self {
        Self::with_timeout(url, TIMEOUT)
    }

    pub(crate) fn with_timeout(url: String, timeout: Duration) -> Self {
        Self { url, timeout }
    }
}

fn kind_word(kind: Kind) -> &'static str {
    match kind {
        Kind::ParkedCall => "approval",
        Kind::GateQuestion => "gate question",
        Kind::Question => "question",
    }
}

/// A header is 1 line of ASCII. The intake already cuts a requester to this many characters; this
/// cuts again because the title is the one place that builds a header, so it holds without the intake.
fn title(item: &Opened) -> String {
    let requester: String = item.requester.chars().take(REQUESTER_CHARS).collect();
    format!("lain {} waiting on {requester}", kind_word(item.kind))
        .chars()
        .map(|c| if (' '..='~').contains(&c) { c } else { '?' })
        .collect()
}

/// The id percent-encoded as Ruby's `ERB::Util.url_encode` does, which the phone's parser decodes.
fn action(id: &str) -> String {
    let encoded: String = id
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                char::from(byte).to_string()
            }
            other => format!("%{other:02X}"),
        })
        .collect();
    format!("view, Open, lain-remote://item/{encoded}")
}

/// 1 notice for a window that dropped items: a count and nothing to open.
fn summary_title(more: usize) -> String {
    format!("lain: {more} more items waiting")
}

impl Notify for Ntfy {
    async fn summarize(&self, more: usize) -> Result<(), String> {
        let (url, title, timeout) = (self.url.clone(), summary_title(more), self.timeout);
        joined(tokio::task::spawn_blocking(move || post(&url, &title, None, timeout)).await)
    }

    async fn notify(&self, item: &Opened) -> Result<(), String> {
        let (url, title, action) = (self.url.clone(), title(item), action(&item.id));
        let timeout = self.timeout;
        // ureq blocks, and a slow topic must not hold a runtime worker.
        joined(
            tokio::task::spawn_blocking(move || post(&url, &title, Some(&action), timeout)).await,
        )
    }
}

/// A blocking task's outcome, a panic included. A panic's text varies, so passing it on would
/// defeat the trace's once-per-error line; it is 1 fixed error instead.
fn joined(result: Result<Result<(), String>, tokio::task::JoinError>) -> Result<(), String> {
    result.map_err(|_| "the notice task failed".to_string())?
}

/// What the platform probe found: a file, and the default directories. The probe's file already
/// folds in `SSL_CERT_FILE` when it names one that exists, which `system_roots_from` then names
/// again; its directories are only the known system ones, so `SSL_CERT_DIR` is read from the
/// environment alone.
#[cfg(not(target_os = "macos"))]
type Probed = (Option<std::path::PathBuf>, Vec<std::path::PathBuf>);

#[cfg(not(target_os = "macos"))]
fn system_roots() -> rustls_native_certs::CertificateResult {
    system_roots_from(
        |name| std::env::var_os(name),
        (
            openssl_probe::probe().cert_file,
            openssl_probe::candidate_cert_dirs()
                .map(std::path::Path::to_path_buf)
                .collect(),
        ),
    )
}

/// `SSL_CERT_FILE` is 1 literal path, as OpenSSL takes it, and `SSL_CERT_DIR` a colon-separated list.
/// A directory is read whole here, every file in it, where OpenSSL reads only hash-named ones.
///
/// `lookup` reads a variable and `probed` is what the platform probe found, both passed in so a
/// test never reads the real environment or the machine's store.
#[cfg(not(target_os = "macos"))]
fn system_roots_from(
    lookup: impl Fn(&str) -> Option<std::ffi::OsString>,
    probed: Probed,
) -> rustls_native_certs::CertificateResult {
    let set = |name| lookup(name).filter(|value| !value.is_empty());
    roots_with(
        set("SSL_CERT_FILE").map(std::path::PathBuf::from),
        set("SSL_CERT_DIR")
            .map(|value| std::env::split_paths(&value).collect())
            .unwrap_or_default(),
        probed,
    )
}

#[cfg(target_os = "macos")]
fn system_roots() -> rustls_native_certs::CertificateResult {
    rustls_native_certs::load_native_certs()
}

/// What OpenSSL does, which `rustls-native-certs` does not once a variable is set (it then drops the
/// system store): `SSL_CERT_FILE` replaces only the default file and `SSL_CERT_DIR` only the
/// default directories, so a user whose file names a private CA can still post to a public topic.
/// The defaults are passed in so the test never reads the machine's store.
#[cfg(not(target_os = "macos"))]
fn roots_with(
    env_file: Option<std::path::PathBuf>,
    env_dirs: Vec<std::path::PathBuf>,
    probed: Probed,
) -> rustls_native_certs::CertificateResult {
    let file = env_file.or(probed.0);
    let dirs = if env_dirs.is_empty() {
        probed.1
    } else {
        env_dirs
    };
    let mut result = rustls_native_certs::load_certs_from_paths(file.as_deref(), None);
    for dir in dirs {
        let more = rustls_native_certs::load_certs_from_paths(None, Some(&dir));
        result.certs.extend(more.certs);
        result.errors.extend(more.errors);
    }
    result
}

/// The system's roots as OpenSSL finds them, so a topic behind a private CA named in
/// `SSL_CERT_FILE` or `SSL_CERT_DIR` works. Only an https topic needs them. On macOS a set variable
/// replaces the keychain, since there is no default file to fall back to.
fn tls_config(url: &str) -> Result<ureq::tls::TlsConfig, String> {
    tls_config_with(url, system_roots)
}

fn tls_config_with(
    url: &str,
    system_roots: impl FnOnce() -> rustls_native_certs::CertificateResult,
) -> Result<ureq::tls::TlsConfig, String> {
    use ureq::tls::{Certificate, RootCerts, TlsConfig, TlsProvider};
    let builder = TlsConfig::builder()
        .provider(TlsProvider::Rustls)
        .unversioned_rustls_crypto_provider(std::sync::Arc::new(
            rustls::crypto::ring::default_provider(),
        ));
    if !url
        .get(..8)
        .is_some_and(|scheme| scheme.eq_ignore_ascii_case("https://"))
    {
        return Ok(builder.build());
    }
    let loaded = system_roots();
    if loaded.certs.is_empty() {
        return Err(format!(
            "no system root certificates could be loaded ({} errors)",
            loaded.errors.len()
        ));
    }
    let roots: Vec<Certificate<'static>> = loaded
        .certs
        .iter()
        .map(|der| Certificate::from_der(der.as_ref()).to_owned())
        .collect();
    Ok(builder.root_certs(RootCerts::from(roots)).build())
}

fn post(url: &str, title: &str, action: Option<&str>, timeout: Duration) -> Result<(), String> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(timeout))
        .http_status_as_error(false)
        // A notice to a topic is never worth a second hop, and following a redirect to an https URL
        // from an http topic panics in ureq, whose text would defeat the trace's once-per-error line.
        .max_redirects(0)
        .tls_config(tls_config(url)?)
        .build()
        .into();
    let mut request = agent.post(url).header("Title", title);
    if let Some(action) = action {
        request = request.header("Actions", action);
    }
    let response = request.send(BODY).map_err(|error| error.to_string())?;
    let status = response.status();
    if status.is_success() {
        Ok(())
    } else {
        Err(format!("ntfy answered {}", status.as_u16()))
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;

    use super::*;

    fn item(id: &str, kind: Kind, requester: &str) -> Opened {
        Opened {
            id: id.to_string(),
            twin: "t".to_string(),
            kind,
            requester: requester.to_string(),
        }
    }

    /// What the stub topic read: the request line, its headers lowercased by name, and the body.
    struct Request {
        line: String,
        headers: Vec<(String, String)>,
        body: String,
    }

    impl Request {
        fn header(&self, name: &str) -> Option<&str> {
            self.headers
                .iter()
                .find(|(have, _)| have == name)
                .map(|(_, value)| value.as_str())
        }
    }

    /// How long a test waits for its stub topic to have heard a request.
    const STUB_WAIT: Duration = Duration::from_secs(10);

    /// A stub that never hears a request must fail its test, not hang it.
    fn request_within(served: std::thread::JoinHandle<Request>, wait: Duration) -> Request {
        let deadline = std::time::Instant::now() + wait;
        while !served.is_finished() {
            assert!(
                std::time::Instant::now() < deadline,
                "no request reached the stub"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        served.join().expect("the stub")
    }

    /// A topic that answers `status` to its first request, and what that request said.
    fn topic(status: u16) -> (String, std::thread::JoinHandle<Request>) {
        topic_with(status, "")
    }

    /// The same, with `extra` header lines (each ending in a CRLF) on the reply.
    fn topic_with(status: u16, extra: &'static str) -> (String, std::thread::JoinHandle<Request>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let url = format!("http://{}/lain-topic", listener.local_addr().expect("addr"));
        let served = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut read = Vec::new();
            let mut chunk = [0_u8; 1024];
            let (head, length) = loop {
                let got = stream.read(&mut chunk).expect("read");
                read.extend_from_slice(&chunk[..got]);
                let text = String::from_utf8_lossy(&read).into_owned();
                if let Some((head, _)) = text.split_once("\r\n\r\n") {
                    let length = head
                        .lines()
                        .find_map(|line| {
                            line.to_lowercase()
                                .strip_prefix("content-length: ")?
                                .parse()
                                .ok()
                        })
                        .unwrap_or(0_usize);
                    break (head.to_string(), length);
                }
            };
            let body_start = head.len() + 4;
            while read.len() < body_start + length {
                let got = stream.read(&mut chunk).expect("read");
                read.extend_from_slice(&chunk[..got]);
            }
            write!(
                stream,
                "HTTP/1.1 {status} X\r\n{extra}content-length: 0\r\nconnection: close\r\n\r\n"
            )
            .expect("reply");
            let mut lines = head.lines();
            Request {
                line: lines.next().unwrap_or_default().to_string(),
                headers: lines
                    .filter_map(|line| line.split_once(": "))
                    .map(|(name, value)| (name.to_lowercase(), value.to_string()))
                    .collect(),
                body: String::from_utf8_lossy(&read[body_start..]).into_owned(),
            }
        });
        (url, served)
    }

    #[tokio::test]
    async fn the_notice_is_a_title_a_link_and_a_fixed_body() {
        let (url, served) = topic(200);
        let notice = Ntfy::new(url)
            .notify(&item("0123abcd", Kind::ParkedCall, "main"))
            .await;
        assert_eq!(Ok(()), notice);
        let request = request_within(served, STUB_WAIT);
        assert_eq!("POST /lain-topic HTTP/1.1", request.line);
        assert_eq!("Open lain to answer.", request.body);
        assert_eq!(
            Some("lain approval waiting on main"),
            request.header("title")
        );
        assert_eq!(
            Some("view, Open, lain-remote://item/0123abcd"),
            request.header("actions")
        );
    }

    #[test]
    fn a_dead_topic_costs_5_seconds_at_most() {
        assert_eq!(Duration::from_secs(5), TIMEOUT);
    }

    #[test]
    fn each_kind_names_what_waits() {
        for (kind, word) in [
            (Kind::ParkedCall, "approval"),
            (Kind::GateQuestion, "gate question"),
            (Kind::Question, "question"),
        ] {
            assert_eq!(
                format!("lain {word} waiting on r"),
                title(&item("i", kind, "r"))
            );
        }
    }

    #[test]
    fn a_requester_that_is_not_ascii_cannot_break_the_header() {
        let title = title(&item("i", Kind::Question, "caf\u{e9}\nX-Evil: 1"));
        assert_eq!("lain question waiting on caf??X-Evil: 1", title);
    }

    #[test]
    fn the_id_in_the_link_is_percent_encoded() {
        assert_eq!(
            "view, Open, lain-remote://item/a%20b%2Fc%3Fd%C3%A9-_.~",
            action("a b/c?d\u{e9}-_.~")
        );
    }

    #[tokio::test]
    async fn a_topic_that_refuses_the_notice_is_an_error_naming_its_status() {
        let (url, served) = topic(500);
        let notice = Ntfy::new(url).notify(&item("i", Kind::Question, "r")).await;
        assert_eq!(Err("ntfy answered 500".to_string()), notice);
        request_within(served, STUB_WAIT);
    }

    #[tokio::test]
    async fn a_topic_nothing_listens_on_is_an_error_not_a_hang() {
        let gone = {
            let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind");
            format!("http://{}/t", listener.local_addr().expect("addr"))
        };
        let notice = Ntfy::new(gone)
            .notify(&item("i", Kind::Question, "r"))
            .await;
        assert!(notice.is_err(), "{notice:?}");
    }

    #[test]
    fn a_requester_is_cut_to_64_characters_in_the_title() {
        let long = "r".repeat(500);
        let title = title(&item("i", Kind::Question, &long));
        assert_eq!(
            format!("lain question waiting on {}", "r".repeat(64)),
            title
        );
    }

    #[tokio::test]
    async fn a_topic_that_accepts_and_never_answers_is_an_error_not_a_hang() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        listener.set_nonblocking(true).expect("nonblocking");
        let url = format!("http://{}/t", listener.local_addr().expect("addr"));
        let (release, released) = std::sync::mpsc::channel::<()>();
        // Bounded in both directions: a notice that never connects must fail the test, not hang it.
        let holder = std::thread::spawn(move || {
            let deadline = std::time::Instant::now() + STUB_WAIT;
            loop {
                match listener.accept() {
                    Ok((held, _)) => {
                        let _ = released.recv_timeout(STUB_WAIT);
                        drop(held);
                        return true;
                    }
                    Err(_) if std::time::Instant::now() < deadline => {
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(_) => return false,
                }
            }
        });
        let notice = tokio::time::timeout(
            STUB_WAIT,
            Ntfy::with_timeout(url, Duration::from_millis(200)).notify(&item(
                "i",
                Kind::Question,
                "r",
            )),
        )
        .await;
        drop(release);
        assert!(
            holder.join().expect("the stub"),
            "the notice never connected"
        );
        assert!(matches!(notice, Ok(Err(_))), "{notice:?}");
    }

    #[test]
    fn a_requester_of_many_multibyte_characters_is_cut_by_characters_not_bytes() {
        let title = title(&item("i", Kind::Question, &"\u{e9}".repeat(100)));
        assert_eq!(
            format!("lain question waiting on {}", "?".repeat(64)),
            title
        );
    }

    #[tokio::test]
    async fn a_summary_is_a_title_and_the_fixed_body_and_carries_no_link() {
        let (url, served) = topic(200);
        assert_eq!(Ok(()), Ntfy::new(url).summarize(7).await);
        let request = request_within(served, STUB_WAIT);
        assert_eq!(Some("lain: 7 more items waiting"), request.header("title"));
        assert_eq!("Open lain to answer.", request.body);
        assert_eq!(None, request.header("actions"));
    }

    #[test]
    fn the_title_keeps_the_printable_ascii_range_and_nothing_either_side_of_it() {
        let title = title(&item("i", Kind::Question, "a b~c\u{7f}\u{1f}"));
        assert_eq!("lain question waiting on a b~c??", title);
    }

    #[test]
    #[should_panic(expected = "no request")]
    fn a_stub_that_hears_nothing_fails_its_test_instead_of_hanging() {
        let (_url, served) = topic(200);
        request_within(served, Duration::from_millis(200));
    }

    /// An https topic on loopback under the fixture CA, which names 127.0.0.1 and whose key is gone.
    fn tls_topic() -> (String, std::sync::mpsc::Receiver<String>) {
        use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
        use std::io::{Read, Write};
        let certs: Vec<CertificateDer<'static>> =
            CertificateDer::pem_slice_iter(include_bytes!("test_tls/server.pem"))
                .collect::<Result<_, _>>()
                .expect("the server certificate");
        let key = PrivateKeyDer::from_pem_slice(include_bytes!("test_tls/server.key"))
            .expect("the server key");
        let config = std::sync::Arc::new(
            rustls::ServerConfig::builder_with_provider(std::sync::Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .expect("protocol versions")
            .with_no_client_auth()
            .with_single_cert(certs, key)
            .expect("the certificate and key match"),
        );
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let url = format!("https://{}/qa", listener.local_addr().expect("addr"));
        let (heard, requests) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let (Ok(mut stream), Ok(mut conn)) = (
                    stream,
                    rustls::ServerConnection::new(std::sync::Arc::clone(&config)),
                ) else {
                    continue;
                };
                let mut tls = rustls::Stream::new(&mut conn, &mut stream);
                let mut text = Vec::new();
                let mut chunk = [0_u8; 1024];
                while !text.windows(4).any(|window| window == b"\r\n\r\n") {
                    match tls.read(&mut chunk) {
                        Ok(0) | Err(_) => break,
                        Ok(got) => text.extend_from_slice(&chunk[..got]),
                    }
                }
                if text.is_empty() {
                    continue;
                }
                let _ = tls.write_all(
                    b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                );
                let _ = heard.send(String::from_utf8_lossy(&text).into_owned());
            }
        });
        (url, requests)
    }

    /// Run by `a_private_ca_named_in_ssl_cert_file...` in a child process, since a process's
    /// environment cannot be changed from a test; it does nothing otherwise.
    #[tokio::test]
    #[ignore = "run only as the child of the private-CA test"]
    async fn tls_child() {
        let Ok(url) = std::env::var("D12_TLS_URL") else {
            return;
        };
        let notice = Ntfy::new(url).notify(&item("i", Kind::Question, "r")).await;
        assert_eq!(Ok(()), notice);
    }

    #[test]
    fn a_private_ca_named_in_ssl_cert_file_is_trusted_and_an_unnamed_one_is_not() {
        let (url, requests) = tls_topic();
        let ca = concat!(env!("CARGO_MANIFEST_DIR"), "/src/test_tls/ca.pem");
        let child = |ca: Option<&str>| {
            let mut command = std::process::Command::new(std::env::current_exe().expect("exe"));
            command
                .args([
                    "--exact",
                    "--ignored",
                    "ntfy::tests::tls_child",
                    "--nocapture",
                ])
                .env("D12_TLS_URL", &url)
                .env_remove("SSL_CERT_FILE")
                .env_remove("SSL_CERT_DIR");
            if let Some(ca) = ca {
                command.env("SSL_CERT_FILE", ca);
            }
            command.output().expect("run the child test")
        };

        let named = child(Some(ca));
        assert!(
            named.status.success(),
            "{}",
            String::from_utf8_lossy(&named.stdout)
        );
        assert!(
            requests
                .recv_timeout(STUB_WAIT)
                .expect("a request over TLS")
                .starts_with("POST /qa ")
        );
        assert!(
            !child(None).status.success(),
            "a certificate no store names was trusted"
        );
    }

    #[cfg(not(target_os = "macos"))]
    fn fixture(name: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("src/test_tls")
            .join(name)
    }

    #[cfg(not(target_os = "macos"))]
    fn ders(path: &str) -> Vec<Vec<u8>> {
        use rustls::pki_types::{CertificateDer, pem::PemObject};
        let bytes = std::fs::read(fixture(path)).expect("a fixture");
        CertificateDer::pem_slice_iter(&bytes)
            .map(|cert| cert.expect("a certificate").to_vec())
            .collect()
    }

    #[cfg(not(target_os = "macos"))]
    fn loaded(file: Option<&str>, dirs: &[&str], probed: (Option<&str>, &[&str])) -> Vec<Vec<u8>> {
        let probed = (
            probed.0.map(fixture),
            probed.1.iter().map(|dir| fixture(dir)).collect(),
        );
        roots_with(
            file.map(fixture),
            dirs.iter().map(|dir| fixture(dir)).collect(),
            probed,
        )
        .certs
        .iter()
        .map(|der| der.to_vec())
        .collect()
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn a_file_in_ssl_cert_file_leaves_the_default_directory_in_the_store_as_openssl_does() {
        let roots = loaded(Some("ca.pem"), &[], (None, &["roots"]));
        assert!(
            roots.contains(&ders("ca.pem")[0]),
            "the named file was dropped"
        );
        assert!(
            roots.contains(&ders("ca2.pem")[0]),
            "the default directory was dropped"
        );
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn ssl_cert_file_replaces_only_the_default_file_and_ssl_cert_dir_only_the_default_directory() {
        let file = loaded(Some("ca2.pem"), &[], (Some("ca.pem"), &[]));
        assert_eq!(
            vec![ders("ca2.pem")[0].clone()],
            file,
            "the default file was kept"
        );
        let dir = loaded(None, &["roots"], (None, &["default_roots"]));
        assert_eq!(
            vec![ders("ca2.pem")[0].clone()],
            dir,
            "the default directory was kept"
        );
        let neither = loaded(None, &[], (Some("ca.pem"), &["roots"]));
        assert_eq!(2, neither.len(), "the defaults were not used");
    }

    #[tokio::test]
    async fn a_topic_that_redirects_is_an_error_naming_the_status_and_is_not_followed() {
        let (url, served) = topic_with(302, "location: https://elsewhere.invalid/t\r\n");
        let notice = Ntfy::new(url).notify(&item("i", Kind::Question, "r")).await;
        assert_eq!(Err("ntfy answered 302".to_string()), notice);
        request_within(served, STUB_WAIT);
    }

    #[tokio::test]
    async fn a_task_that_panics_is_one_fixed_error_whatever_it_said() {
        let outcome = |text: &'static str| async move {
            joined(
                tokio::task::spawn_blocking(move || -> Result<(), String> { panic!("{text}") })
                    .await,
            )
        };
        let (first, second) = (outcome("one 111").await, outcome("two 222").await);
        assert_eq!(first, second);
        assert!(first.is_err());
    }

    #[cfg(not(target_os = "macos"))]
    fn lookup_of(
        pairs: &[(&'static str, std::path::PathBuf)],
    ) -> impl Fn(&str) -> Option<std::ffi::OsString> {
        let pairs = pairs.to_vec();
        move |name| {
            pairs
                .iter()
                .find(|(known, _)| *known == name)
                .map(|(_, value)| value.clone().into_os_string())
        }
    }

    #[cfg(not(target_os = "macos"))]
    fn from_env(
        pairs: &[(&'static str, std::path::PathBuf)],
        probed: (Option<&str>, &[&str]),
    ) -> Vec<Vec<u8>> {
        let probed = (
            probed.0.map(fixture),
            probed.1.iter().map(|dir| fixture(dir)).collect(),
        );
        let mut ders: Vec<Vec<u8>> = system_roots_from(lookup_of(pairs), probed)
            .certs
            .iter()
            .map(|der| der.to_vec())
            .collect();
        ders.sort();
        ders.dedup();
        ders
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn the_variables_replace_only_their_own_default_whichever_are_set() {
        let (ca, ca2) = (ders("ca.pem")[0].clone(), ders("ca2.pem")[0].clone());
        let mut both = vec![ca, ca2.clone()];
        both.sort();
        let file = |name: &str| ("SSL_CERT_FILE", fixture(name));
        let dir = |name: &str| ("SSL_CERT_DIR", fixture(name));
        // The defaults are ca.pem as the file and `default_roots` (ca.pem again) as the directory,
        // except where a case names the other, which holds ca2.pem.
        assert_eq!(
            both,
            from_env(&[], (Some("ca.pem"), &["roots"])),
            "neither variable"
        );
        assert_eq!(
            both,
            from_env(&[file("ca2.pem")], (Some("ca.pem"), &["default_roots"])),
            "the file only: the default directory stays"
        );
        assert_eq!(
            both,
            from_env(&[dir("roots")], (Some("ca.pem"), &["default_roots"])),
            "the directory only: the default file stays"
        );
        assert_eq!(
            both,
            from_env(&[file("ca2.pem"), dir("default_roots")], (None, &[])),
            "both"
        );
        assert_eq!(
            vec![ca2],
            from_env(
                &[file("ca2.pem"), dir("roots")],
                (Some("ca.pem"), &["default_roots"])
            ),
            "both replace every default"
        );
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn ssl_cert_file_is_one_literal_path_even_with_a_colon_in_it() {
        let dir = tempfile::tempdir().expect("a tempdir");
        let named = dir.path().join("a:b.pem");
        std::fs::copy(fixture("ca.pem"), &named).expect("copy");
        let roots = from_env(&[("SSL_CERT_FILE", named)], (None, &[]));
        assert_eq!(ders("ca.pem"), roots);
    }

    #[test]
    fn only_an_https_topic_gets_roots_and_a_capitalised_scheme_counts() {
        use ureq::tls::RootCerts;
        let fixture_roots = || {
            let mut result = rustls_native_certs::CertificateResult::default();
            let bytes = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/src/test_tls/ca.pem"))
                .expect("a fixture");
            use rustls::pki_types::{CertificateDer, pem::PemObject};
            result
                .certs
                .extend(CertificateDer::pem_slice_iter(&bytes).map(|cert| cert.expect("cert")));
            result
        };
        for url in ["https://h/t", "HTTPS://h/t"] {
            let config = tls_config_with(url, fixture_roots).expect("a config");
            assert!(
                matches!(config.root_certs(), RootCerts::Specific(_)),
                "{url} got no roots"
            );
        }
        let config = tls_config_with("http://h/t", || panic!("an http topic asked for roots"))
            .expect("a config");
        assert!(!matches!(config.root_certs(), RootCerts::Specific(_)));
    }

    #[test]
    fn a_store_with_no_roots_is_an_error_naming_how_many_failed() {
        let refused = tls_config_with(
            "https://h/t",
            rustls_native_certs::CertificateResult::default,
        );
        assert!(
            refused.is_err_and(|error| error.contains("no system root certificates")),
            "an https topic was given an empty store"
        );
    }

    /// Run by `a_proxy_named_in_the_environment...` in a child process, which cannot change this
    /// process's environment; it does nothing otherwise.
    #[tokio::test]
    #[ignore = "run only as the child of the proxy test"]
    async fn proxy_child() {
        let Ok(url) = std::env::var("D12_PROXY_TOPIC") else {
            return;
        };
        let notice = Ntfy::new(url).notify(&item("i", Kind::Question, "r")).await;
        assert_eq!(Ok(()), notice);
    }

    /// A proxy that tunnels: answers a `CONNECT`, then the request inside it, and hands on the
    /// request line of each.
    fn tunnelling_proxy() -> (String, std::sync::mpsc::Receiver<String>) {
        use std::io::{Read, Write};
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let address = format!("http://{}", listener.local_addr().expect("addr"));
        let (heard, lines) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            for reply in [
                "HTTP/1.1 200 Connection established\r\n\r\n",
                "HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
            ] {
                let mut text = Vec::new();
                let mut chunk = [0_u8; 1024];
                while !text.windows(4).any(|window| window == b"\r\n\r\n") {
                    match stream.read(&mut chunk) {
                        Ok(0) | Err(_) => return,
                        Ok(got) => text.extend_from_slice(&chunk[..got]),
                    }
                }
                let text = String::from_utf8_lossy(&text).into_owned();
                let _ = heard.send(text.lines().next().unwrap_or_default().to_string());
                let _ = stream.write_all(reply.as_bytes());
            }
        });
        (address, lines)
    }

    /// The test binary run as `ntfy::tests::proxy_child` posting to `topic`, with `http_proxy` at
    /// `proxy`, no other proxy variable, and `no_proxy` as given.
    fn through(topic: &str, proxy: &str, no_proxy: Option<&str>) -> std::process::Output {
        let mut command = std::process::Command::new(std::env::current_exe().expect("exe"));
        command
            .args([
                "--exact",
                "--ignored",
                "ntfy::tests::proxy_child",
                "--nocapture",
            ])
            .env("D12_PROXY_TOPIC", topic);
        for name in [
            "http_proxy",
            "https_proxy",
            "all_proxy",
            "no_proxy",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "NO_PROXY",
        ] {
            command.env_remove(name);
        }
        command.env("http_proxy", proxy);
        if let Some(hosts) = no_proxy {
            command.env("no_proxy", hosts);
        }
        command.output().expect("run the child test")
    }

    #[test]
    fn a_proxy_named_in_the_environment_carries_the_post() {
        let (proxy, lines) = tunnelling_proxy();
        let proxied = through("http://ntfy.invalid/qa", &proxy, None);
        assert!(
            proxied.status.success(),
            "{}{}",
            String::from_utf8_lossy(&proxied.stdout),
            String::from_utf8_lossy(&proxied.stderr)
        );
        let seen: Vec<String> = lines.try_iter().collect();
        assert_eq!(
            vec!["CONNECT ntfy.invalid:80 HTTP/1.1", "POST /qa HTTP/1.1"],
            seen
        );
    }

    #[test]
    fn a_host_on_no_proxy_is_posted_to_directly_and_the_proxy_hears_nothing() {
        let (proxy, lines) = tunnelling_proxy();
        let (topic, served) = topic(200);
        let direct = through(&topic, &proxy, Some("127.0.0.1"));
        assert!(
            direct.status.success(),
            "{}{}",
            String::from_utf8_lossy(&direct.stdout),
            String::from_utf8_lossy(&direct.stderr)
        );
        assert_eq!(
            "POST /lain-topic HTTP/1.1",
            request_within(served, STUB_WAIT).line
        );
        assert_eq!(Vec::<String>::new(), lines.try_iter().collect::<Vec<_>>());
    }

    /// Run by `the_real_environment_and_probe_keep_the_default_roots...` in a child process.
    #[cfg(not(target_os = "macos"))]
    #[test]
    #[ignore = "run only as the child of the default-roots test"]
    fn roots_child() {
        let Some(case) = std::env::var_os("D12_ROOTS_CHILD") else {
            return;
        };
        let got: Vec<Vec<u8>> = system_roots()
            .certs
            .iter()
            .map(|der| der.to_vec())
            .collect();
        let probed = openssl_probe::probe();
        let default_dirs: Vec<std::path::PathBuf> = openssl_probe::candidate_cert_dirs()
            .map(std::path::Path::to_path_buf)
            .collect();
        let load =
            |file: Option<&std::path::Path>, dir: Option<&std::path::Path>| -> Vec<Vec<u8>> {
                rustls_native_certs::load_certs_from_paths(file, dir)
                    .certs
                    .iter()
                    .map(|der| der.to_vec())
                    .collect()
            };
        if case == "file" {
            assert!(
                got.contains(&ders("ca.pem")[0]),
                "the named file was dropped"
            );
            for dir in &default_dirs {
                assert!(
                    load(None, Some(dir)).iter().all(|der| got.contains(der)),
                    "the default directory {} was dropped",
                    dir.display()
                );
            }
        } else {
            // `SSL_CERT_DIR` replaces the default directories: the named one and the default file
            // are all there is, however many other directories the probe knows.
            let mut expected = ders("ca2.pem");
            expected.extend(load(probed.cert_file.as_deref(), None));
            assert!(
                got.contains(&ders("ca2.pem")[0]),
                "the named directory was dropped"
            );
            assert!(
                got.iter().all(|der| expected.contains(der)),
                "a default directory was kept beside the named one"
            );
        }
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn the_real_environment_and_probe_keep_the_defaults_a_variable_does_not_replace() {
        let child = |case: &str, name: &str, value: std::path::PathBuf, unset: &str| {
            let output = std::process::Command::new(std::env::current_exe().expect("exe"))
                .args([
                    "--exact",
                    "--ignored",
                    "ntfy::tests::roots_child",
                    "--nocapture",
                ])
                .env("D12_ROOTS_CHILD", case)
                .env(name, value)
                .env_remove(unset)
                .output()
                .expect("run the child test");
            assert!(
                output.status.success(),
                "{case}: {}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        };
        child("file", "SSL_CERT_FILE", fixture("ca.pem"), "SSL_CERT_DIR");
        child("dir", "SSL_CERT_DIR", fixture("roots"), "SSL_CERT_FILE");
    }
}
