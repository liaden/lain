# frozen_string_literal: true

module Lain
  module Prompt
    # Loads `.lain/slots/*.md` overrides once at session start, then renders the
    # shipped base templates with those holes filled -- purely, in memory. A fill
    # is durable, rarely-changed, freeform adjustment of the system prompt.
    #
    # Because fills change rarely they can safely live in the cached prefix, which
    # is why {LockedBinding} enforces purity: the render is a pure function of
    # (fills, templates), so identical inputs yield identical bytes -- the same
    # constraint `Context#render` lives under, and the reason a fill is
    # content-addressed (see {#digests}) rather than re-read per turn. Mind
    # Anthropic's 4096-token minimum-cacheable-prefix floor, though: the shipped
    # default is ~70 tokens, so the prefix silently will not cache until an
    # override (plus tools) grows past the floor -- eligible-for-the-cache is not
    # the same as cached.
    class Slots
      # Where a project's overrides live, on the `.lain/` convention (like `.git/`).
      SLOTS_DIR = File.join(".lain", "slots")

      # The top-level slots the shipped templates declare holes for. A file naming
      # anything else is a typo surfaced loudly rather than silently ignored.
      KNOWN = %w[system].freeze

      TEMPLATE_DIR = File.expand_path("templates", __dir__)
      private_constant :TEMPLATE_DIR

      # Each shipped built-in role ships a default framing template here, so the
      # set of shipped basenames IS the set of KNOWN role slots -- the
      # role-namespace analogue of {KNOWN}. A `.lain/slots/role/<name>.md` naming
      # no shipped role is a typo surfaced loudly, like a stray top-level file.
      ROLE_TEMPLATE_DIR = File.join(TEMPLATE_DIR, "role")
      private_constant :ROLE_TEMPLATE_DIR

      # The skill slots live TWO levels down: unlike the flat one-per-role
      # region, a skill has many holes. `<skill>/skill.md` here is the scaffold
      # {Skill::Catalog} reads; its sibling `<hole>.md` files are the defaults.
      SKILL_TEMPLATE_DIR = File.join(TEMPLATE_DIR, "skill")
      private_constant :SKILL_TEMPLATE_DIR

      class << self
        # Every filename is validated against {KNOWN} (top-level) and the shipped
        # role set. Session-fixed: this is the one disk read, and #render works
        # from the returned frozen snapshot. The shipped skill dir is injectable
        # so a spec can point the hole defaults at a fixture tree, exactly as
        # {Skill::Catalog.load} injects its shipped scaffolds.
        def load(root: Dir.pwd, skill_shipped_dir: SKILL_TEMPLATE_DIR)
          dir = File.join(root, SLOTS_DIR)
          new(
            fills: read_fills(dir),
            role_fills: read_role_fills(File.join(dir, "role")),
            skill_slots: SkillSlots.new(fills: SkillSlots.read(File.join(dir, "skill")),
                                        templates: SkillSlots.read(skill_shipped_dir))
          )
        end

        # The defaults #render falls back to when a slot has no override.
        def shipped_templates
          @shipped_templates ||= KNOWN.to_h { |name| [name, File.read(template_path(name))] }.freeze
        end

        # Keyed by the on-disk (hyphenated) slot basename -- the registry of
        # KNOWN role slots. Unlike a top-level slot (whose default is empty and
        # whose fill AUGMENTS a base frame), a role's shipped `.md` IS the
        # default framing, and an override REPLACES it.
        def shipped_role_templates
          @shipped_role_templates ||=
            Dir.glob(File.join(ROLE_TEMPLATE_DIR, "*.md"))
               .to_h { |path| [File.basename(path, ".md"), File.read(path)] }.freeze
        end

        # The pinned role-slot filename mapping, owned here: `:test_engineer`
        # resolves the file `.lain/slots/role/test-engineer.md`.
        def role_slot_name(name) = name.to_s.tr("_", "-")

        # No project overrides, shipped hole defaults only -- what a bare
        # {Slots.new} (outside {.load}) renders against.
        def shipped_skill_slots
          @shipped_skill_slots ||= SkillSlots.new(fills: {}, templates: SkillSlots.read(SKILL_TEMPLATE_DIR))
        end

        private

        def read_fills(dir)
          Dir.glob(File.join(dir, "*.md")).each_with_object({}) do |path, fills|
            name = File.basename(path, ".md")
            raise UnknownSlot, "unknown slot file #{path.inspect}; known slots: #{KNOWN.join(", ")}" \
              unless KNOWN.include?(name)

            fills[name] = File.read(path)
          end
        end

        def read_role_fills(dir)
          known = shipped_role_templates
          Dir.glob(File.join(dir, "*.md")).each_with_object({}) do |path, fills|
            name = File.basename(path, ".md")
            raise UnknownSlot, "unknown role slot file #{path.inspect}; known roles: #{known.keys.join(", ")}" \
              unless known.key?(name)

            fills[name] = File.read(path)
          end
        end

        def template_path(name) = File.join(TEMPLATE_DIR, "#{name}.md.erb")
      end

      def initialize(fills:, role_fills: {}, templates: self.class.shipped_templates,
                     role_templates: self.class.shipped_role_templates,
                     skill_slots: self.class.shipped_skill_slots)
        @fills = fills.transform_keys(&:to_s).freeze
        @role_fills = role_fills.transform_keys(&:to_s).freeze
        # The trailing #freeze is SHALLOW -- it stops `@templates = ...`, not
        # `@templates["system"] = ...`. So each template hash is COPIED and
        # frozen on the way in, buying exactly one guarantee: no slot can be
        # grown, replaced or deleted under an already-built Slots, whatever
        # reference the caller kept. It does NOT make this object immutable --
        # the template and fill Strings are still the caller's, `#fills` hands
        # live references out, and `Ractor.shareable?` is false. A copy rather
        # than a freeze in place because the hash belongs to the caller:
        # {.shipped_templates} shares one across every instance, and freezing an
        # argument mutates an object this class does not own.
        @templates = templates.dup.freeze
        @role_templates = role_templates.dup.freeze
        @skill_slots = skill_slots
        freeze
      end

      # The rendered prompt for +slot+, base template plus filled holes. Pure: a
      # function of the frozen fills and templates, byte-identical across calls.
      def render(slot = "system")
        engine = LockedBinding.new(resolve: method(:resolve))
        engine.render_template(@templates.fetch(slot.to_s), slot.to_s)
      end

      # The project override at `.lain/slots/role/<name>.md` if present, else the
      # shipped default. Pure and session-fixed exactly like {#render}, so two
      # spawns of one role render byte-identical -- the cache invariant the role
      # catalog rests on. An impure override fails loudly here, never as a silent
      # nondeterministic value.
      def render_role(name)
        slot = self.class.role_slot_name(name)
        source = @role_fills.fetch(slot) do
          @role_templates.fetch(slot) do
            raise UnknownSlot, "unknown role #{name.inspect}; known roles: #{@role_templates.keys.join(", ")}"
          end
        end
        LockedBinding.new(resolve: method(:resolve)).render_template(source, "role/#{slot}")
      end

      # The pure LEAF render: ONE skill hole, knowing nothing of scaffolds,
      # includes or the catalog -- {Skill::Renderer} composes these into a
      # scaffold. Pure and session-fixed exactly like {#render_role}. A hole with
      # neither override nor shipped default is a loud {UnknownSlot}, never a
      # silent empty fill.
      def render_skill(skill, hole)
        source = @skill_slots.source(skill, hole)
        LockedBinding.new(resolve: method(:resolve)).render_template(source, "skill/#{skill}/#{hole}")
      end

      # The content address of each known slot's RENDERED bytes -- not the fill
      # source: the rendered prompt is what {Telemetry::SlotFills} journals and
      # what same-role siblings must share byte-identically, and a source digest
      # would let one fill under two template versions collide under one address.
      def digests
        KNOWN.to_h { |name| [name, Canonical.digest(render(name))] }
      end

      # The raw override SOURCE behind each known slot -- the bytes a reader
      # diffs to explain why two sessions render differently. Source and address
      # are the two halves of the attribution one {Telemetry::SlotFills} carries;
      # {#digests} is the other.
      def fills
        KNOWN.to_h { |name| [name, resolve(name)] }
      end

      private

      # Top-level slots default to EMPTY: the substance of the shipped default
      # lives in the base template around the hole, so an override AUGMENTS it
      # rather than replacing the frame.
      def resolve(name) = @fills.fetch(name.to_s, "")
    end
  end
end
