# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # The chat's capability floor -- the tier-1 structured tools plus tier-3
      # bash -- before the subagent and the ask_human reply seam layer on. Its
      # own object because "what raw capabilities a chat starts with" is a
      # distinct question from how they are wired (CLAUDE.md: a Metrics trip
      # means an object is missing; extract, never loosen). The union a subagent
      # role attenuates FROM is exactly this list, so it is built once and shared.
      module BaseTools
        module_function

        def build(recorder)
          [Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new, Lain::Tools::Grep.new,
           Lain::Tools::EditFile.new, Lain::Tools::WriteFile.new, Lain::Tools::TodoWrite.new,
           Lain::Tools::MemoryWrite.new(recorder:), Lain::Tools::MemoryRead.new(index: recorder),
           Lain::Tools::Bash.new, Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new, Lain::Tools::AstDump.new,
           Lain::Tools::TestPattern.new, Lain::Tools::AstSearch.new, Lain::Tools::CodeOutline.new,
           Lain::Tools::FileSymbols.new]
        end
      end
    end
  end
end
