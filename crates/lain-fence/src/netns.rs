//! The check behind `--private-net`: this process's network namespace has
//! loopback and nothing else.
//!
//! Read from `/proc/self/net/dev`, which follows the reader's netns. Under a
//! `--ro-bind / /` the sysfs is the host's mount, so `/sys/class/net` lists
//! the host's interfaces from inside a private netns and cannot be trusted.
//!
//! A table of only `lo` cannot tell a private netns from a host netns that
//! happens to have nothing but loopback; on such a host the flag would leave
//! TCP open to the host's own loopback services. The Ruby launcher never
//! relies on this check alone: it passes `--private-net` only together with
//! bwrap's `--unshare-net`, both read from the one `private_net` field of a
//! profile.

const DEV: &str = "/proc/self/net/dev";

/// Fails closed: an unreadable or empty table is refused like a host one.
pub fn ensure_only_loopback() -> Result<(), String> {
    let table =
        std::fs::read_to_string(DEV).map_err(|error| format!("--private-net: {DEV}: {error}"))?;
    let names = interfaces(&table);
    if names == ["lo"] {
        return Ok(());
    }
    Err(format!(
        "--private-net: interfaces {names:?}, not only lo; run it inside a private network namespace"
    ))
}

/// The first 2 lines are column headers; each later line is `name: counters`.
fn interfaces(table: &str) -> Vec<String> {
    table
        .lines()
        .skip(2)
        .filter_map(|line| line.split_once(':'))
        .map(|(name, _)| name.trim().to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEADER: &str = "Inter-|   Receive\n face |bytes    packets\n";

    #[test]
    fn names_every_interface_after_the_header() {
        let table = format!("{HEADER}    lo: 1 2 3\nenp6s0: 4 5 6\n");

        assert_eq!(interfaces(&table), ["lo", "enp6s0"]);
    }

    #[test]
    fn an_empty_table_names_nothing() {
        assert!(interfaces(HEADER).is_empty());
    }
}
