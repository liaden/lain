# frozen_string_literal: true

module Lain
  class Skill
    # What a project can say: the skills it offers ({Catalog}) and the prompt
    # slots they render through ({Prompt::Slots}). Both are the same kind of
    # thing -- one session-fixed read of the shipped defaults overlaid with the
    # project's `.lain/` tree -- and every seam that renders prompt text reads
    # one, the other, or both: the system prompt from the slots, /help from the
    # catalog, a skill scaffold and a role's framing from the pair.
    #
    # It exists because the pair had already stopped being two arguments. T15
    # fixed the real bug (five reads of one tree per session, so a `.lain/` file
    # changed mid-session could give four readers four different answers) by
    # loading each once and threading them -- but they then travelled verbatim
    # as `(catalog:, slots:)` through four signatures, and a parameter list
    # passed identically at every call is the state of an object nobody has
    # named. It is the same tell that named {CLI::Wiring::ToolsetBuild}, and the
    # same answer.
    #
    # {#renderer} is deliberately NOT memoized: a {Renderer} is a pure function
    # of this frozen pair, so building one per reader costs an allocation and
    # buys back the guarantee that nothing can accumulate state on a value.
    # (Nor could it -- Data instances are frozen. That is the point.)
    #
    # Frozen but NOT `Ractor.shareable?`, and the asymmetry is worth knowing:
    # {Catalog} is shareable, {Prompt::Slots} is not (it documents this itself --
    # it hands live references to the caller's template Strings out through
    # `#fills`), so the pair is not. Measured, not assumed.
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
      # overrides, and taking it once here is what retires it from the four
      # signatures downstream -- it lived in those only to feed the from-disk
      # defaults this object replaces.
      def self.load(root: Dir.pwd) = new(catalog: Catalog.load(root:), slots: Prompt::Slots.load(root:))

      # The composition the pair exists for. Two callers need it -- the repl's
      # {Middleware::SkillDispatch} and {Tools::RunSkill} -- and it lived as
      # `ReplMiddleware.renderer` so those two could not drift. Here, they
      # cannot drift because there is only one pair to compose.
      def renderer = Renderer.new(catalog:, slots:)
    end
  end
end
