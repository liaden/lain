# frozen_string_literal: true

module RuboCop
  module Cop
    module Lain
      # Project memory and compaction are two subsystems, and neither reads the other.
      # Project memory is durable fact shared by every chat in the project; compaction
      # is a rebuildable view of one chat's history whose cuts are replaced the moment
      # the chain moves. A compaction file naming project memory would make a handoff's
      # state document durable fact no later chat can un-remember; the consolidation
      # pass naming a cut would let a clerk distill a SUMMARY into memory and cite it
      # as what the chat said.
      #
      # Each rule is an absence, which no behavioural spec can fail, so the source is
      # the subject. Names are read from code only: each subsystem's docstrings state
      # this very boundary in prose, and a text match would fail on them.
      #
      # @example
      #   # bad, under lib/lain/compaction/
      #   Memory::ProjectStore.new(project_dir:)
      #
      #   # bad, in the consolidation pass
      #   records.select { |record| record["type"] == "compaction_cut" }
      class MemoryCompactionSeparation < Base
        MSG = "`%<name>s` belongs to the other subsystem. On this side, %<side>s holds %<holds>s, and " \
              "project memory and compaction never read each other: a handoff's state document is never " \
              "a memory item, and a consolidation clerk reads the chat's own turns, never a cut. If the " \
              "reach is needed, argue the boundary rather than editing the Sides of " \
              "Lain/MemoryCompactionSeparation in .rubocop.yml."

        VARIABLES = %i[lvar lvasgn arg optarg restarg kwarg kwoptarg kwrestarg blockarg shadowarg match_var].freeze

        def on_new_investigation
          side, rule = side_for(config.path_relative_to_config(processed_source.file_path))
          return unless side && processed_source.ast

          processed_source.ast.each_node do |node|
            name, range = name_of(node)
            flag(range, name, side, rule) if rule.fetch("Forbidden").include?(name)
          end
        end

        private

        def side_for(path)
          cop_config.fetch("Sides", {}).find do |_side, rule|
            rule.fetch("Files").any? { |glob| PathUtil.match_path?(glob, path) }
          end
        end

        def name_of(node)
          name = spelling(node)
          [name.to_s, location(node)] if name
        end

        # The old rule lexed every identifier, so any node that spells a name counts.
        def spelling(node)
          case node.type
          when :const then node.short_name
          when :casgn then node.name
          when :send, :csend, :def, :defs then node.method_name
          when :sym, :str then node.value
          when *VARIABLES then node.children.first
          end
        end

        def location(node)
          case node.type
          when :send, :csend then node.loc.selector
          when :sym, :str then node.source_range
          else node.loc.name
          end
        end

        def flag(range, name, side, rule)
          add_offense(range, message: format(MSG, name:, side:, holds: rule.fetch("Holds")))
        end
      end
    end
  end
end
