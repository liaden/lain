//! The two thread-local shapes the bindings share: a bounded cache of built
//! values, and the reach into a thread-local that never panics.

use std::cell::RefCell;
use std::collections::HashMap;
use std::hash::Hash;
use std::rc::Rc;
use std::thread::LocalKey;

/// Built values by language, then by source text.
///
/// Keyed by language first so a hit is looked up by `&str` without allocating
/// the key. Only successes are stored, so a malformed source keeps raising and
/// cannot take a slot. A full cache stops admitting and never evicts: the first
/// entries a thread sees keep their slots, so the cap bounds memory, not cost,
/// and a caller building sources from input still pays a build per call once the
/// slots are gone.
pub struct BoundedCache<L, V> {
    built: HashMap<L, HashMap<String, Rc<V>>>,
    cap: usize,
}

impl<L: Hash + Eq + Copy, V> BoundedCache<L, V> {
    /// An empty cache that admits at most `cap` entries.
    pub fn new(cap: usize) -> Self {
        Self {
            built: HashMap::new(),
            cap,
        }
    }

    /// The cached value for `key` in `lang`, or what `build` makes, kept if a
    /// slot is free.
    pub fn get_or_insert_with<E>(
        &mut self,
        lang: L,
        key: &str,
        build: impl FnOnce() -> Result<V, E>,
    ) -> Result<Rc<V>, E> {
        if let Some(hit) = self.built.get(&lang).and_then(|by_key| by_key.get(key)) {
            return Ok(Rc::clone(hit));
        }
        let value = Rc::new(build()?);
        if self.len() < self.cap {
            self.built
                .entry(lang)
                .or_default()
                .insert(key.to_string(), Rc::clone(&value));
        }
        Ok(value)
    }

    /// Derived rather than counted: a cap is a few dozen, so the sum is cheap
    /// beside the build it guards, and a stored count could drift from the maps.
    fn len(&self) -> usize {
        self.built.values().map(HashMap::len).sum()
    }

    #[cfg(test)]
    pub(crate) fn entries(&self) -> usize {
        self.len()
    }
}

/// Runs `f` against the thread-local in `key`, falling back to a `fresh` one if
/// the thread-local is unreachable (during TLS teardown) or already borrowed
/// (re-entrancy). Neither is reachable from a Ruby method call, but both are
/// panics on the ergonomic API, and a panic unwinding into Ruby is undefined
/// behaviour.
///
/// The `FnMut` bound looks wrong for something called once. It is what lets the
/// fallback call `f` after `try_with` has borrowed and released it, instead of
/// duplicating the body.
pub fn with_local<C: 'static, T>(
    key: &'static LocalKey<RefCell<C>>,
    fresh: impl FnOnce() -> C,
    mut f: impl FnMut(&mut C) -> T,
) -> T {
    key.try_with(|cell| cell.try_borrow_mut().ok().map(|mut local| f(&mut local)))
        .ok()
        .flatten()
        .unwrap_or_else(|| f(&mut fresh()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn built(cache: &mut BoundedCache<u8, String>, lang: u8, key: &str) -> Rc<String> {
        cache
            .get_or_insert_with::<()>(lang, key, || Ok(format!("{lang}:{key}")))
            .unwrap()
    }

    #[test]
    fn a_second_lookup_of_the_same_key_is_the_same_object() {
        let mut cache = BoundedCache::new(8);
        assert!(Rc::ptr_eq(
            &built(&mut cache, 1, "a"),
            &built(&mut cache, 1, "a")
        ));
    }

    #[test]
    fn the_same_key_in_another_language_is_a_separate_entry() {
        let mut cache = BoundedCache::new(8);
        let first = built(&mut cache, 1, "a");
        let second = built(&mut cache, 2, "a");
        assert!(!Rc::ptr_eq(&first, &second));
        assert_eq!(cache.entries(), 2);
    }

    #[test]
    fn failures_are_not_stored_and_the_cap_holds() {
        let mut cache: BoundedCache<u8, String> = BoundedCache::new(3);
        assert_eq!(cache.get_or_insert_with(1, "bad", || Err("no")), Err("no"));
        assert_eq!(cache.entries(), 0, "the failure took no slot");

        let firsts: Vec<_> = (0..4)
            .map(|n| built(&mut cache, 1, &n.to_string()))
            .collect();
        let kept: Vec<bool> = firsts
            .iter()
            .enumerate()
            .map(|(n, first)| Rc::ptr_eq(first, &built(&mut cache, 1, &n.to_string())))
            .collect();

        assert_eq!(kept, vec![true, true, true, false]);
        assert_eq!(cache.entries(), 3);
    }

    thread_local! {
        static LOG: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    }

    #[test]
    fn a_reentrant_call_gets_a_fresh_value_instead_of_a_panic() {
        let inner_saw = with_local(&LOG, Vec::new, |log| {
            log.push(1);
            with_local(&LOG, || vec![9], |inner| inner.clone())
        });
        assert_eq!(inner_saw, vec![9]);
        assert_eq!(LOG.with(|log| log.borrow().clone()), vec![1]);
    }
}
