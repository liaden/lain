# frozen_string_literal: true

module Lain
  class Paths
    # Where the gem ships its OWN data, as opposed to {Paths} proper, which
    # resolves the user's XDG directories from the injected environment. Every
    # member here is a pure fact about the installed gem/checkout -- no `env:`,
    # no instance, nothing to inject -- which is exactly why it does not belong
    # on {Paths}'s instance API alongside `#home`/`#state_home`/etc.
    #
    # Ten `__dir__`-relative computations had accumulated across the codebase,
    # each rederiving "the gem root" at its OWN file's depth (`../`, `../..`,
    # `../../..`) with no shared notion of what that root even was.
    # {NVIM_PLUGIN_ROOT} was the accidental exception -- one of the ten already
    # lived on {Paths} -- which is the seam this file finishes cutting: {GEM_ROOT}
    # is computed ONCE, here, and every shipped path is a join against it.
    #
    # {Structural::Queries} keeps its own per-call join ({.query_path}) rather
    # than a precomputed constant -- eagerly listing `queries/` at load time
    # would cost every boot for a tier-1 tool's lookup that may never run.
    module Shipped
      # This file sits at `lib/lain/paths/shipped.rb`, so three levels up from
      # `__dir__` is the repo/gem root -- the same root {Core::Child::BINARY}
      # and {NVIM_PLUGIN_ROOT} each reached independently, at their own depth.
      GEM_ROOT = File.expand_path("../../..", __dir__)

      # {Core::Child::WORKSPACE_TARGET}: where `cargo build` writes when
      # `CARGO_TARGET_DIR` names nothing. A build OUTPUT, not a shipped file --
      # grouped with the rest because it is the same gem-root arithmetic, not
      # because it ships with the gem.
      CARGO_WORKSPACE_TARGET = File.join(GEM_ROOT, "target")

      # {Frontend::Neovim} injects this tree's `rtp`; {CLI::Up::Cockpit}
      # decides what a missing one means (a degrade, with a warning), so this
      # stays a plain path -- the existence check belongs to the caller that
      # knows what to do about it.
      NVIM_PLUGIN_ROOT = File.join(GEM_ROOT, "plugin", "nvim")

      # {Prompt::Slots}' shipped base templates: the flat top-level slots
      # directly here, the per-role and per-skill fills one level down.
      PROMPT_TEMPLATES_DIR = File.join(GEM_ROOT, "lib", "lain", "prompt", "templates")

      # {Frontend::PromptComposer}'s shipped `prompt.toml` -- the last of the
      # three candidates {PromptComposer.config_path} tries, so it is the one
      # never existence-checked: nothing ranks below it to fall back to.
      DEFAULT_PROMPT_CONFIG = File.join(GEM_ROOT, "lib", "lain", "prompt", "default.toml")

      # {Frontend::Neovim::RuntimeLoader}'s injected chunk: the handshake head
      # and the numbered-module directory it concatenates in order.
      NEOVIM_RUNTIME_HEAD = File.join(GEM_ROOT, "lib", "lain", "frontend", "neovim", "runtime.lua")
      NEOVIM_RUNTIME_MODULES_DIR = File.join(GEM_ROOT, "lib", "lain", "frontend", "neovim", "runtime")

      # {Skill::Catalog}'s shipped skills tree, a sibling of the prompt
      # templates -- a project's own `.lain/skills/` overlays this one.
      SKILL_SHIPPED_DIR = File.join(GEM_ROOT, "lib", "lain", "prompt", "templates", "skill")

      # {Bench::Sweep}'s committed gold corpus and its embeddings, shipped WITH
      # THE GEM rather than under `spec/` -- an installed gem has no `spec/`
      # tree, and the eval is bound to exactly this gold set.
      BENCH_CORPUS_PATH = File.join(GEM_ROOT, "lib", "lain", "bench", "corpus", "retrieval_corpus.yml")
      BENCH_EMBEDDINGS_PATH = File.join(GEM_ROOT, "lib", "lain", "bench", "corpus", "corpus_embeddings.json")

      # {Structural::Queries}' authored tree-sitter query source, resolved per
      # call rather than as a directory constant -- see the class comment.
      #
      # @param language [Symbol]
      # @param query_name [Symbol]
      # @return [String] path to the authored `.scm` file, whether or not it exists
      def self.query_path(language, query_name)
        File.join(GEM_ROOT, "lib", "lain", "structural", "queries", language.to_s, "#{query_name}.scm")
      end
    end
  end
end
