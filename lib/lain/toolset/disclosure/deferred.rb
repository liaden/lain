# frozen_string_literal: true

module Lain
  class Toolset
    class Disclosure
      # The on-demand arm: a searchable CATALOG upfront -- each tool's name and
      # a one-line description, never its input_schema -- with the full schema
      # fetched later, one tool at a time, via {Lain::Tools::ToolSearch}.
      #
      # Withholding here is only the upfront half of the seam; the gate that
      # matters is downstream, in ToolSearch, which must search over the exact
      # same (possibly attenuated) Toolset handed to it. This class cannot
      # enforce that, but it cannot leak either: #render only ever walks the
      # Toolset it is given, so an attenuated-away tool is never a candidate.
      class Deferred < Disclosure
        def render(toolset)
          Canonical.normalize(toolset.map { |tool| catalog_entry(tool) })
        end

        private

        # {Tool#one_line_description}, not {Tool#description} -- the same
        # projection {Tools::ToolSearch} matches queries against, so search
        # can never surface text this catalog withholds.
        def catalog_entry(tool)
          { "name" => tool.name, "description" => tool.one_line_description }
        end
      end
    end
  end
end
