use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::net::SocketAddr;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use dioxus::prelude::*;

/// Where the app finds its relay and how it proves itself there.
#[derive(Clone, PartialEq, Eq)]
pub struct Settings {
  addr: SocketAddr,
  token: String,
}

impl std::fmt::Debug for Settings {
  fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
    f.debug_struct("Settings")
      .field("addr", &self.addr)
      .field("token", &"<saved>")
      .finish()
  }
}

impl Settings {
  /// A blank token keeps the previous one, because a saved token is never shown to be retyped.
  pub fn from_form(previous: Option<&Self>, addr: &str, token: &str) -> Result<Self, String> {
    let addr = addr
      .trim()
      .parse()
      .map_err(|_| format!("{} is not an address:port", addr.trim()))?;
    let token = match (token.trim(), previous) {
      ("", Some(previous)) => previous.token.clone(),
      ("", None) => return Err("the pairing token is empty".to_string()),
      (token, _) => token.to_string(),
    };
    Ok(Self { addr, token })
  }

  pub fn socket_addr(&self) -> SocketAddr {
    self.addr
  }

  pub fn token(&self) -> &str {
    &self.token
  }

  pub const TOKEN_HINT: &'static str = "a token is saved; leave blank to keep it";

  pub fn load(path: &Path) -> Option<Self> {
    let text = fs::read_to_string(path).ok()?;
    let mut lines = text.lines();
    Self::from_form(None, lines.next()?, lines.next()?).ok()
  }

  pub fn save(&self, path: &Path) -> io::Result<()> {
    if let Some(parent) = path.parent() {
      fs::create_dir_all(parent)?;
    }
    let mut temp = path.as_os_str().to_owned();
    temp.push(".tmp");
    let temp = PathBuf::from(temp);
    let mut file = OpenOptions::new()
      .write(true)
      .create(true)
      .truncate(true)
      .mode(0o600)
      .open(&temp)?;
    // `mode` only applies to a new file, and a temp left by a crash may be looser.
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    writeln!(file, "{}\n{}", self.addr, self.token)?;
    file.sync_all()?;
    fs::rename(&temp, path)
  }
}

/// `LAIN_REMOTE_CONFIG`, else the XDG config directory, else `~/.config`.
pub fn default_path() -> Option<PathBuf> {
  if let Some(path) = std::env::var_os("LAIN_REMOTE_CONFIG") {
    return Some(PathBuf::from(path));
  }
  let base = std::env::var_os("XDG_CONFIG_HOME")
    .map(PathBuf::from)
    .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
  Some(base.join("lain-remote").join("settings"))
}

#[component]
pub fn SettingsForm(current: Option<Settings>, save: EventHandler<Settings>, close: EventHandler<()>) -> Element {
  let mut addr = use_signal(|| {
    current
      .as_ref()
      .map_or_else(String::new, |settings| settings.socket_addr().to_string())
  });
  let mut token = use_signal(String::new);
  let mut problem = use_signal(String::new);
  let hint = current.as_ref().map_or("pairing token", |_| Settings::TOKEN_HINT);
  let previous = current.clone();

  rsx! {
    h2 { "Settings" }
    input { placeholder: "relay address:port", value: "{addr}", oninput: move |event| addr.set(event.value()) }
    input {
      r#type: "password",
      placeholder: hint,
      value: "{token}",
      oninput: move |event| token.set(event.value()),
    }
    p { "{problem}" }
    button {
      onclick: move |_| {
        let form = Settings::from_form(previous.as_ref(), &addr(), &token());
        match form {
          Ok(settings) => {
            token.set(String::new());
            save.call(settings);
          }
          Err(message) => problem.set(message),
        }
      },
      "Save"
    }
    if current.is_some() {
      button { onclick: move |_| close.call(()), "Back" }
    }
  }
}

#[cfg(test)]
mod tests {
  use std::os::unix::fs::PermissionsExt;

  use super::Settings;

  #[test]
  fn saved_settings_load_back() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("remote").join("settings");
    let settings = Settings::from_form(None, "100.64.0.2:7421", "secret-token").expect("valid");

    settings.save(&path).expect("save");

    assert_eq!(Some(settings), Settings::load(&path));
  }

  #[test]
  fn a_reader_holding_the_old_file_never_sees_it_rewritten_in_place() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("settings");
    Settings::from_form(None, "127.0.0.1:1", "old-token")
      .expect("valid")
      .save(&path)
      .expect("save");
    let mut reader = std::fs::File::open(&path).expect("open");

    Settings::from_form(None, "127.0.0.1:2", "new-token")
      .expect("valid")
      .save(&path)
      .expect("save");

    let mut seen = String::new();
    std::io::Read::read_to_string(&mut reader, &mut seen).expect("read");
    assert_eq!("127.0.0.1:1\nold-token\n", seen);
    let names: Vec<_> = std::fs::read_dir(dir.path())
      .expect("dir")
      .map(|entry| entry.expect("entry").file_name())
      .collect();
    assert_eq!(1, names.len(), "no temp file is left behind");
  }

  #[test]
  fn the_saved_file_is_readable_by_its_owner_only() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("settings");

    Settings::from_form(None, "127.0.0.1:1", "secret-token")
      .expect("valid")
      .save(&path)
      .expect("save");

    let mode = std::fs::metadata(&path).expect("metadata").permissions().mode();
    assert_eq!(0o600, mode & 0o777);
  }

  #[test]
  fn saving_over_a_looser_file_tightens_it() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("settings");
    std::fs::write(&path, "old").expect("write");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).expect("chmod");

    Settings::from_form(None, "127.0.0.1:1", "secret-token")
      .expect("valid")
      .save(&path)
      .expect("save");

    let mode = std::fs::metadata(&path).expect("metadata").permissions().mode();
    assert_eq!(0o600, mode & 0o777);
  }

  #[test]
  fn a_missing_or_garbled_file_loads_as_nothing() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("settings");
    assert_eq!(None, Settings::load(&path));

    std::fs::write(&path, "not settings").expect("write");
    assert_eq!(None, Settings::load(&path));
  }

  #[test]
  fn the_token_never_appears_in_debug_output() {
    let settings = Settings::from_form(None, "127.0.0.1:1", "secret-token").expect("valid");

    assert!(!format!("{settings:?}").contains("secret-token"));
  }

  #[test]
  fn a_blank_token_keeps_the_saved_one() {
    let saved = Settings::from_form(None, "127.0.0.1:1", "secret-token").expect("valid");

    let edited = Settings::from_form(Some(&saved), "127.0.0.1:2", "").expect("valid");

    assert_eq!("secret-token", edited.token());
    assert_eq!("127.0.0.1:2", edited.socket_addr().to_string());
  }

  #[test]
  fn a_first_pairing_needs_a_token_and_a_real_address() {
    assert!(Settings::from_form(None, "127.0.0.1:1", " ").is_err());
    assert!(Settings::from_form(None, "not-an-address", "token").is_err());
  }
}
