# frozen_string_literal: true

module Lain
  module Structural
    # The ast-grep pattern catalog seeded from Joel's `~/.zsh/ag_helpers`: six
    # hand-rolled regex helpers (`ragfn`, `ragclass`, `ragisa`, `ragcon`, `ragar`,
    # `ragiv`, `ragfnc`) are a real-world enumeration of the queries a Ruby dev
    # reaches for, and each maps to one or more ast-grep pattern TEMPLATES --
    # written in ast-grep's own metavariable syntax ($NAME, $SUPER, ...), so an
    # unfilled template is already a valid, general ast-grep pattern in its own
    # right. #fetch fills a template's metavariable(s) with literal args when
    # given, and returns the bare template otherwise.
    #
    # `ragar` (ActiveRecord subclasses) is not a separate entry: it differs from
    # `ragisa`'s generic superclass match only by WHICH superclass literal fills
    # $SUPER, so it folds into :subclass_of's `super:` argument rather than
    # duplicating a query.
    module Patterns
      # An unknown language or query name -- named in the message, per the
      # project's loud-failure convention: no query ever answers a typo with nil.
      class Unknown < Error; end

      # One named query: a set of ast-grep pattern templates plus the mapping
      # from an interpolation key (:name, :super, ...) to the literal
      # metavariable token that key fills.
      Query = Data.define(:templates, :metavariables) do
        # The template patterns with every metavariable in +args+ replaced by
        # its literal value. A key with no matching metavariable is a caller
        # bug, not a data problem, so it raises plainly rather than being
        # silently ignored.
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
            pattern.gsub(token, value)
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
          # the catalog covers both `thing.save` and a bare `save` use --
          # ast-grep's `save` still matches every identifier use, distinct from
          # `save!` (a different CST node), giving the caller the granularity
          # ragfnc's regex could only approximate.
          method_call: Query.new(
            templates: ["$RECV.$NAME", "$NAME"],
            metavariables: { name: "$NAME" }
          )
        }.freeze
      }.freeze

      module_function

      # The concrete ast-grep pattern string(s) for +query+ in +language+, with
      # any given args substituted into their metavariables. Raises {Unknown},
      # naming the unrecognized value, for an unknown language OR an unknown
      # query -- never returns nil.
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
