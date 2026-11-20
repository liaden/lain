# frozen_string_literal: true

module Lain
  class Skill
    # Composes a skill's scaffold into finished prompt bytes: the scaffold is
    # rendered ONCE, each declared hole filled via {Prompt::Slots#render_skill}
    # (the pure LEAF render), each statically-declared `include` inlined by
    # rendering the named skill in turn. Composition lives HERE, not in the
    # locked binding: the Renderer holds the catalog and the slots, and the
    # binding stays a pure leaf that only evaluates one template.
    #
    # == Splice, never a second ERB pass
    #
    # A rendered hole or include is FINISHED markdown and must never be fed back
    # through ERB: a fragment whose OUTPUT bytes look like ERB (`<%- ...`,
    # `<%%`) would be re-parsed on a second pass and silently mangled --
    # `50%% off <%- code` collapses to `50%% off  code`, bytes dropped with no
    # error. So each hole and include is a {Prompt::LockedBinding} value, which
    # the scaffold's ONE ERB pass splices in afterward. Purity is still enforced
    # at the legitimate first eval: an impure scaffold fails in its own render
    # pass, an impure hole in {Prompt::Slots#render_skill} before it is ever a
    # fragment.
    #
    # An include cycle (A includes B includes A) is caught by a render stack and
    # surfaced as {Prompt::CircularSlot} naming the chain. The stack lives here
    # rather than in the binding because each skill's scaffold renders in its
    # OWN binding (its holes resolve against ITS slots), so the binding's
    # per-template guard cannot see across an include.
    #
    # Rendering is a pure function of the frozen catalog and frozen slots, so
    # identical inputs yield byte-identical output.
    class Renderer
      def initialize(catalog:, slots:, locals: {})
        @catalog = catalog
        @slots = slots
        @locals = locals
      end

      # The finished scaffold bytes for +skill_name+, holes filled and includes
      # inlined. Pure and byte-stable.
      def render(skill_name)
        compose(@catalog.fetch(skill_name), [])
      end

      private

      def compose(skill, stack)
        raise Prompt::CircularSlot, "skill include cycle: #{(stack + [skill.name]).join(" -> ")}" \
          if stack.include?(skill.name)

        Prompt::LockedBinding.new(resolve: unknown(skill), locals: @locals, values: fragments(skill, stack))
                             .render_template(skill.scaffold, "skill/#{skill.name}")
      end

      # Each declared hole and include, rendered only when the scaffold names it.
      def fragments(skill, stack)
        inside = stack + [skill.name]
        (skill.slots | skill.includes).to_h { |ref| [ref.to_s, -> { fragment_for(skill, ref, inside) }] }
      end

      # A scaffold name declared NEITHER a hole (front-matter `slots`) nor an
      # include (front-matter `includes`) is a loud authoring error, never a
      # silent empty splice.
      def unknown(skill)
        lambda do |name|
          raise Prompt::UnknownSlot,
                "skill #{skill.name.inspect} scaffold references #{name.to_sym.inspect}, which is " \
                "neither a declared slot #{skill.slots.inspect} nor an include #{skill.includes.inspect}"
        end
      end

      def fragment_for(skill, ref, stack)
        resolve_hole(skill, ref) || resolve_include(skill, ref, stack)
      end

      def resolve_hole(skill, ref)
        @slots.render_skill(skill.name, ref, locals: @locals) if skill.slots.include?(ref)
      end

      def resolve_include(skill, ref, stack)
        compose(@catalog.fetch(ref), stack) if skill.includes.include?(ref)
      end
    end
  end
end
