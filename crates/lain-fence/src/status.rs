//! The one JSON line that says what the fence enforced.
//!
//! Landlock's compatibility is best effort: a kernel older than a right silently
//! drops it. This line is where that drop becomes visible to the caller.

use landlock::{ABI, Access, AccessFs, AccessNet, BitFlags, LandlockStatus, Scope};
use serde_json::{Map, Value, json};

/// Kept apart from what the kernel grants, so a right the kernel cannot handle
/// is reported as dropped rather than vanishing from the report.
pub struct Requested {
    pub fs: BitFlags<AccessFs>,
    pub net: BitFlags<AccessNet>,
    pub scope: BitFlags<Scope>,
}

pub struct Status {
    abi: i64,
    rights: Map<String, Value>,
    skipped: Vec<String>,
}

impl Status {
    pub fn new(requested: &Requested, landlock: LandlockStatus, skipped: &[String]) -> Self {
        let effective = ABI::from(landlock);
        let mut rights = Map::new();
        judge(&mut rights, requested.fs, AccessFs::from_all(effective));
        judge(&mut rights, requested.net, AccessNet::from_all(effective));
        judge(&mut rights, requested.scope, Scope::from_all(effective));
        Status {
            abi: kernel_abi(landlock),
            rights,
            skipped: skipped.to_vec(),
        }
    }

    pub fn line(&self) -> String {
        let object = json!({ "abi": self.abi, "rights": self.rights, "skipped": self.skipped });
        format!("{object}\n")
    }
}

fn judge<T: Access + std::fmt::Debug>(
    into: &mut Map<String, Value>,
    requested: BitFlags<T>,
    supported: BitFlags<T>,
) {
    for right in requested.iter() {
        let verdict = if supported.contains(right) {
            "enforced"
        } else {
            "dropped"
        };
        into.insert(snake_case(&format!("{right:?}")), verdict.into());
    }
}

fn kernel_abi(landlock: LandlockStatus) -> i64 {
    match landlock {
        LandlockStatus::Available {
            kernel_abi: Some(newer),
            ..
        } => newer.into(),
        LandlockStatus::Available { effective_abi, .. } => effective_abi as i64,
        LandlockStatus::NotEnabled | LandlockStatus::NotImplemented => 0,
    }
}

fn snake_case(camel: &str) -> String {
    camel
        .chars()
        .enumerate()
        .fold(String::new(), |mut out, (i, c)| {
            if c.is_ascii_uppercase() && i > 0 {
                out.push('_');
            }
            out.push(c.to_ascii_lowercase());
            out
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use landlock::{ABI, AccessFs, AccessNet, LandlockStatus, Scope};

    fn requested() -> Requested {
        Requested {
            fs: AccessFs::Execute | AccessFs::Refer | AccessFs::Truncate | AccessFs::IoctlDev,
            net: AccessNet::ConnectTcp.into(),
            scope: Scope::AbstractUnixSocket | Scope::Signal,
        }
    }

    fn kernel(abi: ABI) -> LandlockStatus {
        LandlockStatus::Available {
            effective_abi: abi,
            kernel_abi: None,
        }
    }

    fn verdicts(status: &Status) -> serde_json::Value {
        serde_json::from_str::<serde_json::Value>(&status.line()).unwrap()["rights"].clone()
    }

    #[test]
    fn a_right_newer_than_the_kernel_is_dropped() {
        let status = Status::new(&requested(), kernel(ABI::V3), &[]);

        assert_eq!(
            verdicts(&status),
            serde_json::json!({
                "execute": "enforced",
                "refer": "enforced",
                "truncate": "enforced",
                "ioctl_dev": "dropped",
                "connect_tcp": "dropped",
                "abstract_unix_socket": "dropped",
                "signal": "dropped",
            })
        );
    }

    #[test]
    fn without_landlock_every_right_is_dropped_and_the_abi_is_zero() {
        let status = Status::new(&requested(), LandlockStatus::NotEnabled, &[]);
        let line: serde_json::Value = serde_json::from_str(&status.line()).unwrap();

        assert_eq!(line["abi"], 0);
        assert!(
            verdicts(&status)
                .as_object()
                .unwrap()
                .values()
                .all(|v| v == "dropped")
        );
    }

    #[test]
    fn the_abi_reported_is_the_kernels_even_when_newer_than_the_crate() {
        let landlock = LandlockStatus::Available {
            effective_abi: ABI::V9,
            kernel_abi: Some(11),
        };

        let line: serde_json::Value =
            serde_json::from_str(&Status::new(&requested(), landlock, &[]).line()).unwrap();

        assert_eq!(line["abi"], 11);
    }

    #[test]
    fn the_line_names_skipped_paths_and_ends_in_one_newline() {
        let skipped = vec!["/no/such\ndir".to_string()];

        let line = Status::new(&requested(), kernel(ABI::V9), &skipped).line();

        assert_eq!(line.matches('\n').count(), 1);
        assert!(line.ends_with('\n'));
        let parsed: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(parsed["skipped"], serde_json::json!(["/no/such\ndir"]));
    }
}
