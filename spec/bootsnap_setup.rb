# frozen_string_literal: true

# Bootsnap for every boot the suite pays: the suite itself (required at the
# top of spec_helper, before "lain") and each fresh-ruby subprocess (the
# prelude invariant spec `-r`s this file ahead of "lain"). Iseq caching is
# semantics-neutral -- the compiled code behaves identically, cold or warm --
# so the byte-identity invariant is untouched; only the require time drops.
# The cache lives under gitignored tmp/cache unless LAIN_BOOTSNAP_CACHE names
# another, and rebuilds lazily, so a cold cache is slower, never wrong. Only
# sources under the repo and the gem dirs are cached: bootsnap never evicts, so
# a per-run copy of the tree would otherwise add entries nothing reads again.
require "bootsnap"

module LainBootsnap
  REPO = File.expand_path("..", __dir__)
  ROOTS = [REPO, RbConfig::CONFIG["rubylibprefix"], *Gem.path].map { "#{_1}/" }.freeze
  SCRATCH = "#{REPO}/tmp/".freeze

  module InTreeIseqCache
    def fetch(path, ...) = cached?(path.to_s) ? super : nil

    def cached?(path) = !path.start_with?(SCRATCH) && ROOTS.any? { path.start_with?(_1) }
  end
end

Bootsnap.setup(cache_dir: ENV.fetch("LAIN_BOOTSNAP_CACHE", File.join(LainBootsnap::REPO, "tmp/cache")))
Bootsnap::CompileCache::ISeq.singleton_class.prepend(LainBootsnap::InTreeIseqCache)
