# frozen_string_literal: true

module Lain
  # Named HOLES in Lain's base prompt that a user fills with markdown partials --
  # the mental model is a Rails view partial, not a scripting language. A slot fill
  # is "inject this markdown doc here": durable, rarely-changed, freeform adjustment
  # of the system prompt that gets the agent into the user's perspective quickly.
  #
  # Because fills change rarely they can safely live in the cached prefix, which is
  # why {LockedBinding} enforces purity: the render is a pure function of (fills,
  # templates), so identical inputs yield identical bytes -- the same constraint
  # `Context#render` lives under, and the reason a fill is content-addressed
  # (see {#digests}) rather than re-read per turn. Mind Anthropic's 4096-token
  # minimum-cacheable-prefix floor, though: the shipped default is ~70 tokens, so
  # the prefix silently will not cache until an override (plus tools) grows past
  # the floor -- eligible-for-the-cache is not the same as cached.
  module Prompt
    # Loads `.lain/slots/*.md` overrides once at session start, then renders the
    # shipped base templates with those holes filled -- purely, in memory.
    class Slots
      # Where a project's overrides live, on the `.lain/` convention (like `.git/`).
      SLOTS_DIR = File.join(".lain", "slots")

      # The top-level slots the shipped templates declare holes for. A file naming
      # anything else is a typo we surface loudly rather than silently ignore.
      # (Namespaced `role/*` and `compaction` slots are later units; this cut is
      # system-level only.)
      KNOWN = %w[system].freeze

      TEMPLATE_DIR = File.expand_path("templates", __dir__)
      private_constant :TEMPLATE_DIR

      # The role slots (M5 role catalog, PS-3) live one level down, at
      # `.lain/slots/role/<name>.md`, and each shipped built-in role ships a
      # default framing template here -- so the set of shipped basenames IS the
      # set of KNOWN role slots, the role-namespace analogue of {KNOWN}. A role
      # file naming no shipped role is a typo surfaced loudly, exactly like a
      # stray top-level file.
      ROLE_TEMPLATE_DIR = File.join(TEMPLATE_DIR, "role")
      private_constant :ROLE_TEMPLATE_DIR

      class << self
        # Read the overrides under +root+/.lain/slots, validating every filename
        # against {KNOWN} (top-level) and the shipped role set (the `role/`
        # subdir). Session-fixed: this is the one disk read; #render works from
        # the returned frozen snapshot.
        def load(root: Dir.pwd)
          dir = File.join(root, SLOTS_DIR)
          new(fills: read_fills(dir), role_fills: read_role_fills(File.join(dir, "role")))
        end

        # The shipped base template per known slot, read once and memoized. These
        # are the defaults #render falls back to when a slot has no override.
        def shipped_templates
          @shipped_templates ||= KNOWN.to_h { |name| [name, File.read(template_path(name))] }.freeze
        end

        # The shipped default framing per role, keyed by the on-disk (hyphenated)
        # slot basename -- the registry of KNOWN role slots. Read once, memoized.
        # Unlike a top-level slot (whose default is empty and whose fill AUGMENTS
        # a base frame), a role's shipped `.md` IS the default framing, and a
        # `.lain/slots/role/<name>.md` override REPLACES it.
        def shipped_role_templates
          @shipped_role_templates ||=
            Dir.glob(File.join(ROLE_TEMPLATE_DIR, "*.md"))
               .to_h { |path| [File.basename(path, ".md"), File.read(path)] }.freeze
        end

        # The pinned role-slot filename mapping (owned here): a role name's
        # underscores become hyphens, so `:test_engineer` resolves the file
        # `.lain/slots/role/test-engineer.md`.
        def role_slot_name(name) = name.to_s.tr("_", "-")

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
                     role_templates: self.class.shipped_role_templates)
        @fills = fills.transform_keys(&:to_s).freeze
        @role_fills = role_fills.transform_keys(&:to_s).freeze
        @templates = templates
        @role_templates = role_templates
        freeze
      end

      # The rendered prompt for +slot+, base template plus filled holes. Pure: a
      # function of the frozen fills and templates, byte-identical across calls.
      def render(slot = "system")
        engine = LockedBinding.new(resolve: method(:resolve))
        engine.render_template(@templates.fetch(slot.to_s), slot.to_s)
      end

      # The rendered framing for a subagent role (PS-3): the project override at
      # `.lain/slots/role/<name>.md` if present, else the shipped default. Pure
      # and session-fixed exactly like {#render}, so two spawns of one role in a
      # session render byte-identical -- the cache invariant the role catalog
      # rests on. Purity is enforced (an impure override fails loudly here, never
      # a silent nondeterministic value), the same guarantee top-level slots hold.
      def render_role(name)
        slot = self.class.role_slot_name(name)
        source = @role_fills.fetch(slot) do
          @role_templates.fetch(slot) do
            raise UnknownSlot, "unknown role #{name.inspect}; known roles: #{@role_templates.keys.join(", ")}"
          end
        end
        LockedBinding.new(resolve: method(:resolve)).render_template(source, "role/#{slot}")
      end

      # The content address of each known slot's RENDERED bytes, keyed by slot
      # name. Rendered, not the fill source: the rendered prompt is what PS-2
      # journals and what same-role siblings must share byte-identically, and a
      # source digest would let two differently-rendering fills (same fill under
      # two template versions) collide under one address.
      def digests
        KNOWN.to_h { |name| [name, Canonical.digest(render(name))] }
      end

      # The raw override SOURCE behind each known slot, keyed by slot name --
      # the bytes a reader diffs to explain why two sessions render differently.
      # Empty string for a slot with no project override (its substance lives in
      # the base template around the hole). Pairs with {#digests}, which
      # content-addresses the RENDERED bytes: source and address are the two
      # halves of the PS-2 slot attribution one {Telemetry::SlotFills} carries.
      def fills
        KNOWN.to_h { |name| [name, resolve(name)] }
      end

      private

      # A slot's active partial source: the project override if present, else the
      # shipped default fill. Top-level slots default to empty -- the substance of
      # the shipped default lives in the base template around the hole, and the
      # override AUGMENTS it rather than replacing the frame.
      def resolve(name) = @fills.fetch(name.to_s, "")
    end
  end
end
