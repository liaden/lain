# frozen_string_literal: true

module Lain
  class Toolset
    class Disclosure
      # The on-demand arm (T13): renders a searchable CATALOG upfront --
      # each tool's name and a one-line description, never its input_schema --
      # and leaves the full schema to be fetched later, one tool at a time,
      # via {Lain::Tools::ToolSearch}.
      #
      # Rendering here is the ONLY place a schema is withheld; the gate that
      # matters is downstream, in ToolSearch, which must search over the exact
      # same (possibly attenuated) Toolset ever handed to it. This class does
      # not enforce that -- it just proves the upfront half of the seam: a
      # tool this Toolset was attenuated away from was never even a candidate
      # here, because #render only ever walks the Toolset it is given.
      class Deferred < Disclosure
        def render(toolset)
          Canonical.normalize(toolset.map { |tool| catalog_entry(tool) })
        end

        private

        # {Tool#one_line_description}, not {Tool#description} -- the same
        # projection {Tools::ToolSearch} matches queries against, so search
        # can never surface text this catalog withholds. See that method's
        # comment for why this is one shared method rather than two copies.
        def catalog_entry(tool)
          { "name" => tool.name, "description" => tool.one_line_description }
        end
      end
    end
  end
end
