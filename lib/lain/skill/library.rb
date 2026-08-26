# frozen_string_literal: true

module Lain
  class Skill
    # What a project can say: the skills it offers ({Catalog}) and the prompt
    # slots they render through ({Prompt::Slots}) -- one session-fixed read of
    # the shipped defaults overlaid with the project's `.lain/` tree. Every seam
    # that renders prompt text reads one, the other, or both.
    #
    # It exists because the pair had stopped being two arguments: they travelled
    # verbatim as `(catalog:, slots:)` through four signatures, and a parameter
    # list passed identically at every call is the state of an object nobody has
    # named. Loading each once is also what fixed five reads of one tree per
    # session giving four readers four different answers.
    #
    # {#renderer} is deliberately NOT memoized: a {Renderer} is a pure function
    # of this frozen pair, so building one per reader costs an allocation and
    # buys back the guarantee that nothing can accumulate state on a value.
    #
    # Frozen but NOT `Ractor.shareable?`, and the asymmetry is worth knowing:
    # {Catalog} is shareable, {Prompt::Slots} is not (it hands live references
    # to the caller's template Strings out through `#fills`), so the pair is
    # not. Measured, not assumed.
    #
    # ⚠️ `Ractor.make_shareable(library)` does NOT raise. It SUCCEEDS, by deep-
    # freezing the caller's template Strings inside the Slots -- so a reader who
    # reaches for it to "fix" the shareability gets silence and a side effect on
    # objects Slots deliberately does not own, not an error. Same silent-freeze
    # trap {CLI::CompactionStrategy} documents for the compaction path.
    #
    # Nor do two loads of one tree compare `eq`: neither half defines `==`, and
    # Data's member-wise equality is only ever as deep as its members.
    Library = Data.define(:catalog, :slots) do
      # The session's one read. `root:` is where BOTH halves find their `.lain/`
      # overrides, and taking it once here retires it from four signatures.
      def self.load(root: Dir.pwd) = new(catalog: Catalog.load(root:), slots: Prompt::Slots.load(root:))

      # The composition the pair exists for. Two callers need it -- the repl's
      # {Middleware::SkillDispatch} and {Tools::RunSkill} -- and they cannot
      # drift because there is only one pair to compose.
      def renderer = Renderer.new(catalog:, slots:)
    end
  end
end
