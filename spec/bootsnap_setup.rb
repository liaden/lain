# frozen_string_literal: true

# Bootsnap for every boot the suite pays: the suite itself (required at the
# top of spec_helper, before "lain") and each fresh-ruby subprocess (the
# prelude invariant spec `-r`s this file ahead of "lain"). Iseq caching is
# semantics-neutral -- the compiled code behaves identically, cold or warm --
# so the byte-identity invariant is untouched; only the require time drops.
# The cache lives under gitignored tmp/cache and rebuilds lazily, so a cold
# cache is slower, never wrong.
require "bootsnap"
Bootsnap.setup(cache_dir: File.expand_path("../tmp/cache", __dir__))
