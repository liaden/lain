# frozen_string_literal: true

module Lain
  module Structural
    # The ast-grep pattern catalog, seeded from the hand-rolled regex helpers in
    # `~/.zsh/ag_helpers` -- a real-world enumeration of the queries a Ruby dev
    # reaches for. Each maps to one or more pattern TEMPLATES written in
    # ast-grep's own metavariable syntax ($NAME, $SUPER, ...), so an unfilled
    # template is already a valid, general ast-grep pattern in its own right.
    #
    # `ragar` (ActiveRecord subclasses) is not a separate entry: it differs from
    # `ragisa`'s generic superclass match only by WHICH superclass literal fills
    # $SUPER, so it folds into :subclass_of's `super:` argument.
    module Patterns
      # An unknown language or query name, named in the message: no query ever
      # answers a typo with nil.
      class Unknown < Error; end

      # One named query: a set of ast-grep pattern templates plus the mapping
      # from an interpolation key (:name, :super, ...) to the literal
      # metavariable token that key fills.
      Query = Data.define(:templates, :metavariables) do
        # The template patterns with every metavariable in +args+ replaced by
        # its literal value. A key with no matching metavariable is a caller
        # bug, so it raises rather than being silently ignored.
        def render(args)
          templates.map { |template| interpolate(template, args) }
        end

        private

        def interpolate(template, args)
          args.reduce(template) do |pattern, (key, value)|
            token = metavariables.fetch(key) do
              raise ArgumentError, "#{self.class} has no metavariable for #{key.inspect}, " \
                                   "expected one of #{metavariables.keys.inspect}"
            end
            # Block form: the replacement is verbatim, no backslash-sequence
            # expansion. The two-arg form treats \1, \&, etc. in +value+ as
            # backreferences into the (nonexistent, since +token+ is a plain
            # String) match groups, silently mangling any value that happens
            # to contain one.
            pattern.gsub(token) { value }
          end
        end
      end
      private_constant :Query

      # language -> query name -> Query. Ruby is the only language seeded so
      # far, mirroring ag_helpers, which was Ruby-only.
      CATALOG = {
        ruby: {
          # ragfn: matches both a plain method def and the singleton-method
          # form. `def $NAME` alone does NOT match `def self.x` -- a distinct
          # CST node -- so both templates are load-bearing, not redundant.
          method_def: Query.new(
            templates: ["def $NAME($$$A)", "def self.$NAME($$$A)"],
            metavariables: { name: "$NAME" }
          ),
          # ragclass: a class or module definition.
          class_def: Query.new(
            templates: ["class $N", "module $N"],
            metavariables: { name: "$N" }
          ),
          # ragisa + ragar unified: a subclass, generically or of a given
          # superclass literal (ragar's ActiveRecord::Base/ApplicationRecord
          # check is just this with `super:` filled in).
          subclass_of: Query.new(
            templates: ["class $C < $SUPER"],
            metavariables: { name: "$C", super: "$SUPER" }
          ),
          # ragcon: metaprogramming mixin, either form.
          mixin: Query.new(
            templates: ["include $M", "extend $M"],
            metavariables: { name: "$M" }
          ),
          # ragiv: an instance (or, deliberately per ragiv, class) variable.
          instance_var: Query.new(
            templates: ["@$VAR"],
            metavariables: { name: "$VAR" }
          ),
          # ragfnc: a call to a method, with a receiver or bare. Two forms so
          # the catalog covers both `thing.save` and a bare `save` -- ast-grep's
          # `save` matches every identifier use and is distinct from `save!` (a
          # different CST node), a granularity ragfnc's regex only approximated.
          method_call: Query.new(
            templates: ["$RECV.$NAME", "$NAME"],
            metavariables: { name: "$NAME" }
          )
        }.freeze
      }.freeze

      module_function

      # The concrete ast-grep pattern string(s) for +query+ in +language+, with
      # any given args substituted into their metavariables. Raises {Unknown},
      # naming the unrecognized value -- never returns nil.
      #
      # @param language [Symbol]
      # @param query [Symbol]
      # @param args [Hash] interpolation values, e.g. name: "save"
      # @return [Array<String>]
      def fetch(language, query, **args)
        queries = CATALOG.fetch(language) do
          raise Unknown, "unknown language #{language.inspect}, expected one of #{CATALOG.keys.inspect}"
        end
        template = queries.fetch(query) do
          raise Unknown, "unknown query #{query.inspect} for #{language.inspect}, " \
                         "expected one of #{queries.keys.inspect}"
        end
        template.render(args)
      end
    end
  end
end
