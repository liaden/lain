//! The phone's side of the relay: one authenticated connection that keeps the
//! open agenda by cursor and sends the human's answers.

use std::io;
use std::net::SocketAddr;

use lain_wire::{AgendaItem, AgendaPage, Answer, Cursor, Hello, WIRE_VERSION, Welcome};
use rmpv::Value;
use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;

/// The relay never sends a frame over this, so a bigger buffer is a broken peer.
const MAX_FRAME: usize = 1 << 20;

#[derive(Debug, thiserror::Error)]
pub enum Error {
  #[error("the relay connection failed: {0}")]
  Io(#[from] io::Error),
  #[error("the relay closed the connection")]
  Closed,
  #[error("the relay refused: {0}")]
  Rpc(String),
  #[error("the relay sent something unreadable: {0}")]
  Wire(String),
}

impl Error {
  fn is_connection(&self) -> bool {
    matches!(self, Self::Io(_) | Self::Closed)
  }
}

/// msgpack-RPC over any byte stream: one request in flight at a time.
pub(crate) struct Rpc<S> {
  stream: S,
  buffer: Vec<u8>,
  next_msgid: u32,
}

impl<S: AsyncRead + AsyncWrite + Unpin> Rpc<S> {
  pub(crate) fn new(stream: S) -> Self {
    Self { stream, buffer: Vec::new(), next_msgid: 1 }
  }

  pub(crate) async fn call(&mut self, method: &str, params: Vec<Value>) -> Result<Value, Error> {
    let msgid = self.next_msgid;
    self.next_msgid = self.next_msgid.wrapping_add(1);
    let request = Value::Array(vec![
      Value::from(0),
      Value::from(msgid),
      Value::from(method),
      Value::Array(params),
    ]);
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, &request).map_err(|error| Error::Wire(error.to_string()))?;
    self.stream.write_all(&bytes).await?;
    let reply = self.read_frame().await?;
    reply_to(&reply, msgid)
  }

  async fn read_frame(&mut self) -> Result<Value, Error> {
    loop {
      let mut reader = io::Cursor::new(self.buffer.as_slice());
      match rmpv::decode::read_value(&mut reader) {
        Ok(value) => {
          let used = usize::try_from(reader.position()).unwrap_or(usize::MAX);
          self.buffer.drain(..used);
          return Ok(value);
        }
        Err(error) if !is_incomplete(&error) => return Err(Error::Wire(error.to_string())),
        Err(_) => {}
      }
      let mut chunk = vec![0u8; 64 << 10];
      let read = self.stream.read(&mut chunk).await?;
      if read == 0 {
        return Err(Error::Closed);
      }
      self.buffer.extend_from_slice(chunk.get(..read).unwrap_or_default());
      if self.buffer.len() > MAX_FRAME {
        return Err(Error::Wire(format!("a frame passes {MAX_FRAME} bytes")));
      }
    }
  }
}

fn is_incomplete(error: &rmpv::decode::Error) -> bool {
  use rmpv::decode::Error::{InvalidDataRead, InvalidMarkerRead};
  matches!(
      error,
      InvalidMarkerRead(source) | InvalidDataRead(source) if source.kind() == io::ErrorKind::UnexpectedEof
  )
}

/// The result of `[1, msgid, error, result]`, or the error the relay put there.
fn reply_to(reply: &Value, msgid: u32) -> Result<Value, Error> {
  let unreadable = || Error::Wire(format!("not a reply: {reply}"));
  let Value::Array(parts) = reply else {
    return Err(unreadable());
  };
  let [kind, id, error, result] = parts.as_slice() else {
    return Err(unreadable());
  };
  if kind.as_u64() != Some(1) || id.as_u64() != Some(u64::from(msgid)) {
    return Err(unreadable());
  }
  match error {
    Value::Nil => Ok(result.clone()),
    Value::String(text) => Err(Error::Rpc(text.to_string())),
    other => Err(Error::Rpc(other.to_string())),
  }
}

fn to_value<T: Serialize>(message: &T) -> Result<Value, Error> {
  let bytes = lain_wire::encode(message).map_err(|error| Error::Wire(error.to_string()))?;
  rmpv::decode::read_value(&mut bytes.as_slice()).map_err(|error| Error::Wire(error.to_string()))
}

fn from_value<T: DeserializeOwned>(value: &Value) -> Result<T, Error> {
  let mut bytes = Vec::new();
  rmpv::encode::write_value(&mut bytes, value).map_err(|error| Error::Wire(error.to_string()))?;
  lain_wire::decode(&bytes).map_err(|error| Error::Wire(error.to_string()))
}

/// A paired phone's view of the relay's agenda. It reconnects with its last
/// cursor when the connection is gone, so a drop costs one round trip, not a refetch.
pub struct Session {
  addr: SocketAddr,
  token: String,
  connection: Option<Rpc<TcpStream>>,
  epoch: Option<u64>,
  cursor: u64,
  open: Vec<AgendaItem>,
}

impl Session {
  pub async fn connect(addr: SocketAddr, token: &str) -> Result<Self, Error> {
    let mut session = Self {
      addr,
      token: token.to_string(),
      connection: None,
      epoch: None,
      cursor: 0,
      open: Vec::new(),
    };
    session.reconnect().await?;
    Ok(session)
  }

  /// What waits on the human now, oldest first.
  pub fn items(&self) -> &[AgendaItem] {
    &self.open
  }

  /// Waits for the agenda to change and applies it. True when the relay sent
  /// a snapshot, so what the session held before is gone.
  pub async fn next(&mut self) -> Result<bool, Error> {
    let at = Cursor { cursor: self.cursor, epoch: self.epoch };
    let page: AgendaPage = self.call("agenda.next", &at).await?;
    if page.reset {
      self.open.clear();
    }
    for delta in page.deltas {
      for item in delta.added {
        self.open.retain(|held| id_of(held) != id_of(&item));
        self.open.push(item);
      }
      self.open.retain(|held| !delta.settled.iter().any(|id| id == id_of(held)));
    }
    self.cursor = page.cursor;
    self.epoch = Some(page.epoch);
    Ok(page.reset)
  }

  pub async fn answer(&mut self, answer: &Answer) -> Result<(), Error> {
    self.call_raw("answer.send", answer).await.map(drop)
  }

  async fn call<T: Serialize, R: DeserializeOwned>(&mut self, method: &str, message: &T) -> Result<R, Error> {
    from_value(&self.call_raw(method, message).await?)
  }

  async fn call_raw<T: Serialize>(&mut self, method: &str, message: &T) -> Result<Value, Error> {
    if self.connection.is_none() {
      self.reconnect().await?;
    }
    let param = to_value(message)?;
    let result = match self.connection.as_mut() {
      Some(connection) => connection.call(method, vec![param]).await,
      None => Err(Error::Closed),
    };
    if result.as_ref().is_err_and(Error::is_connection) {
      self.connection = None;
    }
    result
  }

  async fn reconnect(&mut self) -> Result<(), Error> {
    let stream = TcpStream::connect(self.addr).await?;
    stream.set_nodelay(true)?;
    let mut connection = Rpc::new(stream);
    let hello = Hello {
      wire_version: WIRE_VERSION,
      token: self.token.clone(),
      // The relay ignores it (resuming is the cursor in `agenda.next`) but the type requires one.
      cursor: 0,
    };
    let welcome: Welcome = from_value(&connection.call("hello", vec![to_value(&hello)?]).await?)?;
    if welcome.wire_version != WIRE_VERSION {
      return Err(Error::Wire(format!("the relay speaks wire version {}", welcome.wire_version)));
    }
    self.connection = Some(connection);
    Ok(())
  }

  #[cfg(test)]
  fn cursor(&self) -> u64 {
    self.cursor
  }

  #[cfg(test)]
  fn sever(&mut self) {
    self.connection = None;
  }
}

fn id_of(item: &AgendaItem) -> &str {
  match item {
    AgendaItem::ParkedCall { id, .. } | AgendaItem::GateQuestion { id, .. } | AgendaItem::Question { id, .. } => id,
  }
}

#[cfg(test)]
mod tests {
  use std::net::{SocketAddr, TcpStream};
  use std::os::unix::fs::PermissionsExt;
  use std::path::{Path, PathBuf};
  use std::process::{Child, Command, Stdio};
  use std::time::{Duration, Instant};

  use lain_wire::{AgendaItem, Answer, AnswersPage, Cursor, Delta};
  use tokio::net::UnixStream;

  use super::{Error, Rpc, Session, from_value, to_value};

  const TOKEN: &str = "a-paired-phone-token";
  const DEVICE: &str = "test-phone";
  const DEFAULT_BIN: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../target/debug/lain-daemon");

  struct Relay {
    child: Child,
    dir: tempfile::TempDir,
    _devices: tempfile::TempDir,
    phone: SocketAddr,
  }

  /// A skipped suite looks green, so CI sets the flag to turn a missing binary into a failure.
  fn lain_daemon_bin(configured: Option<&str>, required: bool) -> Option<String> {
    let bin = configured.unwrap_or(DEFAULT_BIN);
    if Path::new(bin).is_file() {
      return Some(bin.to_string());
    }
    let advice = format!("no lain-daemon at {bin}; build it with `cargo build -p lain-daemon` or set LAIN_DAEMON_BIN");
    assert!(!required, "{advice}");
    eprintln!("skipping: {advice}");
    None
  }

  /// Tries this many ports before giving up, since a chosen port can be taken before the relay binds it.
  const SPAWN_ATTEMPTS: usize = 5;

  impl Relay {
    fn start() -> Option<Self> {
      Self::start_on(std::iter::repeat_with(free_loopback_address).take(SPAWN_ATTEMPTS))
    }

    fn start_on(addresses: impl IntoIterator<Item = SocketAddr>) -> Option<Self> {
      let configured = std::env::var("LAIN_DAEMON_BIN").ok();
      let required = std::env::var_os("LAIN_REMOTE_REQUIRE_RELAY").is_some();
      let bin = lain_daemon_bin(configured.as_deref(), required)?;
      let mut exits = Vec::new();
      for phone in addresses {
        match Self::spawn(&bin, phone) {
          Ok(relay) => return Some(relay),
          Err(status) => exits.push(format!("{phone}: {status}")),
        }
      }
      panic!("the relay never started: {exits:?}");
    }

    /// The relay's exit status when it dies before listening.
    fn spawn(bin: &str, phone: SocketAddr) -> Result<Self, std::process::ExitStatus> {
      let dir = tempfile::tempdir().expect("a tempdir");
      let devices = tempfile::tempdir().expect("a devices directory");
      std::fs::set_permissions(devices.path(), std::fs::Permissions::from_mode(0o700)).expect("chmod the directory");
      let devices_file = devices.path().join("devices");
      let line = format!("{DEVICE} {}\n", blake3::hash(TOKEN.as_bytes()).to_hex());
      std::fs::write(&devices_file, line).expect("write the devices file");
      std::fs::set_permissions(&devices_file, std::fs::Permissions::from_mode(0o600)).expect("chmod the devices file");
      let child = Command::new(bin)
        .arg("relay")
        .arg("--unix")
        .arg(dir.path().join("relay.sock"))
        .arg("--listen")
        .arg(phone.to_string())
        .arg("--devices-file")
        .arg(&devices_file)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn lain-daemon");
      let mut relay = Self { child, dir, _devices: devices, phone };
      relay.wait_until_listening()?;
      Ok(relay)
    }

    fn wait_until_listening(&mut self) -> Result<(), std::process::ExitStatus> {
      let deadline = Instant::now() + Duration::from_secs(10);
      while TcpStream::connect(self.phone).is_err() || !self.socket().exists() {
        if let Some(status) = self.child.try_wait().expect("poll the relay") {
          return Err(status);
        }
        assert!(Instant::now() < deadline, "the relay never listened on {}", self.phone);
        std::thread::sleep(Duration::from_millis(25));
      }
      Ok(())
    }

    fn socket(&self) -> PathBuf {
      self.dir.path().join("relay.sock")
    }

    async fn lain(&self) -> Rpc<UnixStream> {
      Rpc::new(UnixStream::connect(self.socket()).await.expect("connect lain"))
    }

    async fn publish(&self, delta: &Delta) {
      let result = self
        .lain()
        .await
        .call("agenda.publish", vec![to_value(delta).expect("encode")])
        .await;
      result.expect("publish");
    }

    async fn answers(&self) -> AnswersPage {
      let at = Cursor { cursor: 0, epoch: None };
      let page = self
        .lain()
        .await
        .call("answers.next", vec![to_value(&at).expect("encode")])
        .await;
      from_value(&page.expect("answers.next")).expect("an answers page")
    }
  }

  impl Drop for Relay {
    fn drop(&mut self) {
      let _ = self.child.kill();
      let _ = self.child.wait();
    }
  }

  fn free_loopback_address() -> SocketAddr {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind a free port");
    listener.local_addr().expect("the bound address")
  }

  fn question(id: &str) -> AgendaItem {
    AgendaItem::Question {
      id: id.to_string(),
      requester: "main".to_string(),
      question: "which branch?".to_string(),
      options: vec!["main".to_string(), "dev".to_string()],
      asked_at: 1_700_000_000,
      session: "s1".to_string(),
      project: "/work".to_string(),
    }
  }

  fn adding(item: AgendaItem) -> Delta {
    Delta { cursor: 0, added: vec![item], settled: vec![] }
  }

  fn settling(id: &str) -> Delta {
    Delta {
      cursor: 0,
      added: vec![],
      settled: vec![id.to_string()],
    }
  }

  fn ids(session: &Session) -> Vec<&str> {
    session
      .items()
      .iter()
      .map(|item| match item {
        AgendaItem::ParkedCall { id, .. } | AgendaItem::GateQuestion { id, .. } | AgendaItem::Question { id, .. } => {
          id.as_str()
        }
      })
      .collect()
  }

  #[tokio::test]
  async fn lists_a_published_item_answers_it_and_resumes_after_a_drop() {
    let Some(relay) = Relay::start() else { return };
    relay.publish(&adding(question("q1"))).await;
    relay.publish(&adding(question("q3"))).await;

    let mut session = Session::connect(relay.phone, TOKEN).await.expect("connect");
    session.next().await.expect("the first page");
    assert_eq!(vec!["q1", "q3"], ids(&session));

    let answer = Answer::Question {
      id: "q1".to_string(),
      option: Some("dev".to_string()),
      text: None,
      device: None,
    };
    session.answer(&answer).await.expect("answer q1");
    assert_eq!(vec![answer.stamped_by(DEVICE)], relay.answers().await.answers);

    relay.publish(&settling("q1")).await;
    let reset = session.next().await.expect("the settle");
    assert!(!reset);
    assert_eq!(vec!["q3"], ids(&session));

    let cursor = session.cursor();
    session.sever();
    let mut again = question("q3");
    if let AgendaItem::Question { question, .. } = &mut again {
      *question = "which branch, really?".to_string();
    }
    relay
      .publish(&Delta {
        cursor: 0,
        added: vec![question("q2"), again],
        settled: vec![],
      })
      .await;
    let reset = session.next().await.expect("resume after the drop");

    assert!(!reset, "the relay kept the cursor, so no snapshot");
    assert_eq!(cursor + 1, session.cursor(), "only the one new delta came, not a replay");
    assert_eq!(vec!["q2", "q3"], ids(&session), "q3 kept once, q2 added");
  }

  #[tokio::test]
  async fn items_from_two_sessions_in_two_projects_reach_the_phone_grouped_and_openable() {
    use crate::ui::agenda::{Opening, groups, open_link};

    let Some(relay) = Relay::start() else { return };
    let mut elsewhere = question("q2");
    if let AgendaItem::Question { session, project, .. } = &mut elsewhere {
      *session = "s2".to_string();
      *project = "/other".to_string();
    }
    relay.publish(&adding(question("q1"))).await;
    relay.publish(&adding(elsewhere)).await;
    relay.publish(&settling("q1")).await;
    relay.publish(&adding(question("q3"))).await;

    let mut session = Session::connect(relay.phone, TOKEN).await.expect("connect");
    session.next().await.expect("the first page");

    let placed: Vec<_> = groups(session.items(), 1_700_000_100)
      .into_iter()
      .map(|group| (group.project, group.session, group.rows.len()))
      .collect();
    assert_eq!(
      vec![
        ("/work".to_string(), "s1".to_string(), 1),
        ("/other".to_string(), "s2".to_string(), 1)
      ],
      placed
    );
    assert_eq!(
      Some(Opening::Select("q2".to_string())),
      open_link(session.items(), "lain-remote://item/q2")
    );
    assert_eq!(
      Some(Opening::Settled("q1".to_string())),
      open_link(session.items(), "lain-remote://item/q1")
    );
  }

  #[tokio::test]
  async fn a_cursor_from_another_epoch_gets_a_snapshot_that_replaces_what_was_held() {
    let Some(relay) = Relay::start() else { return };
    relay.publish(&adding(question("q1"))).await;
    let mut session = Session::connect(relay.phone, TOKEN).await.expect("connect");
    session.next().await.expect("the first page");
    session.open.push(question("ghost"));
    session.epoch = Some(session.epoch.expect("an epoch") ^ 1);

    let reset = session.next().await.expect("the snapshot");

    assert!(reset);
    assert_eq!(vec!["q1"], ids(&session));
  }

  #[test]
  #[should_panic(expected = "cargo build -p lain-daemon")]
  fn a_required_relay_that_is_missing_fails_instead_of_skipping() {
    let _ = lain_daemon_bin(Some("/nonexistent/lain-daemon"), true);
  }

  #[test]
  fn a_missing_relay_skips_when_not_required() {
    assert_eq!(None, lain_daemon_bin(Some("/nonexistent/lain-daemon"), false));
  }

  #[tokio::test]
  async fn a_port_taken_between_choosing_and_binding_is_retried() {
    let taken = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("hold a port");
    let taken_address = taken.local_addr().expect("the held address");
    let free = free_loopback_address();

    let Some(relay) = Relay::start_on([taken_address, free]) else { return };

    assert_eq!(free, relay.phone);
  }

  #[tokio::test]
  async fn a_second_answer_to_the_same_item_is_refused() {
    let Some(relay) = Relay::start() else { return };
    relay.publish(&adding(question("q1"))).await;
    let mut session = Session::connect(relay.phone, TOKEN).await.expect("connect");
    session.next().await.expect("the first page");
    let answer = Answer::Question {
      id: "q1".to_string(),
      option: None,
      text: Some("later".to_string()),
      device: None,
    };
    session.answer(&answer).await.expect("the first answer");

    let again = session.answer(&answer).await;

    assert!(matches!(again, Err(Error::Rpc(message)) if message.contains("settled")));
  }

  #[tokio::test]
  async fn a_wrong_token_is_refused_at_connect() {
    let Some(relay) = Relay::start() else { return };

    let refused = Session::connect(relay.phone, "not-the-token").await;

    assert!(matches!(refused, Err(Error::Rpc(_))), "{:?}", refused.err());
  }
}
