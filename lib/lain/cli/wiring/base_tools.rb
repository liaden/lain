# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # The chat's capability floor -- the tier-1 structured tools plus tier-3
      # bash -- before the subagent and the ask_human reply seam layer on. The
      # union a subagent role attenuates FROM is exactly this list, so it is
      # built once and shared.
      module BaseTools
        module_function

        # @param recorder [Lain::Memory::Recorder] the ONE recorder backing the
        #   memory tools for the whole session
        # @param exec [#call] the {Lain::Exec} backend {Lain::Tools::Bash}
        #   becomes a process through -- `--exec`, resolved by
        #   {Lain::CLI::ExecBackend} at the site that knows the project's root.
        #   Defaulted rather than required so the callers that only want the
        #   floor's SHAPE stay byte-identical to before the flag existed.
        # @param verdict [#call] `String -> Shell::Verdict::Decision`, the
        #   session's ONE shell verdict -- the object {Lain::Tools::Bash} picks
        #   its arm with AND the object the approval ladder's triage rung
        #   judges with. {Lain::CLI::Wiring} builds it from the project's
        #   `[shell]` table and hands the same instance to both, which is what
        #   makes "the journalled verdict is the verdict the tool acted on"
        #   true by construction: the object is frozen and pure, so two holders
        #   of ONE instance compute the identical Decision from the identical
        #   String, and nothing has to be carried between the gate and the tool.
        #
        #   The default restricts no program, so a floor built with no session
        #   -- `bash_spec` constructs the tool alone, and
        #   {Lain::Tools::Subagent} runs an ungated handler -- is unchanged.
        #   Sharing the instance is an INJECTION and never a dependency: the
        #   tool must stay correct with nobody above it. The default is written
        #   here rather than in a constant because `lain.rb` loads `lain/cli`
        #   before `lain/shell`, so it can only be resolved at CALL time --
        #   the same debt `escalation.rb` records at the other seam.
        #
        #   == A DENY MOVES THE COMMAND ONTO THE LESS CONSTRAINED ARM
        #
        #   Stated here because this is where the verdict reaches the object
        #   that picks the arm, and a reader reasoning about arms will not
        #   think to look at a Switchboard keyword. `Tools::Bash#perform` is
        #   `decision.allow? ? decision.term : input.command`, so `deny` and
        #   `abstain` are one branch to it. MEASURED, through the real tool
        #   over a recording backend:
        #
        #     no table          curl http://example.com  allow  [["curl","http://example.com"]]
        #     exclude = ["curl"] curl http://example.com  deny   "curl http://example.com"
        #
        #   So excluding a program takes it OFF the reconstructed argv this
        #   layer exists to produce and onto `sh -c` -- more shell, not less,
        #   for the one program the project named. Attended sessions never see
        #   it, because the ladder's triage rung denies before the tool is
        #   reached. The two postures that DO reach the tool are exactly the
        #   two that skip the ladder: `/mode auto`, whose gate policy is
        #   {Effect::Handler::Gate::ApproveAll} (`mode/resolution.rb:107`), and
        #   a child spawned over {Lain::Tools::Subagent::UNGATED}
        #   (`subagent.rb:311`), which is the same class.
        #
        #   NOT a defect this card may fix: what a deny should MEAN at the tool
        #   -- refuse outright, or run as a term anyway -- is a design question
        #   about the tool's contract rather than about the wiring, and the
        #   answer changes `Tools::Bash`. Named instead as the NEXT RUNG on the
        #   chunk's "what reaches a shell" axis, whose position today is
        #   "understood commands run as reconstructed argv; everything else
        #   through `sh -c`": the rung after it is a deny that does not fall
        #   through to the string arm.
        # @param journal [#<<] the session's journal, where {Lain::Tools::Bash}
        #   writes the {Lain::Telemetry::ShellArm} record of every call's arm.
        #   Handed down by {Lain::CLI::Wiring::ToolsetBuild}, which holds the
        #   run's one journal already. Null by default for the same reason
        #   `verdict:` is permissive by default -- a floor built with no session
        #   behind it must still work -- and, for the same reason, the default is
        #   what a spec has to drive PAST rather than through, or arm selection
        #   would go unrecorded in every real session while looking wired here.
        def build(recorder, exec: Lain::Exec::Local.new, verdict: Lain::Shell::Verdict.new,
                  journal: Lain::Channel::Null.instance)
          [Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new, Lain::Tools::Grep.new,
           Lain::Tools::EditFile.new, Lain::Tools::WriteFile.new, Lain::Tools::TodoWrite.new,
           Lain::Tools::MemoryWrite.new(recorder:), Lain::Tools::MemoryRead.new(index: recorder),
           Lain::Tools::Bash.new(exec:, verdict:, journal:), Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new,
           Lain::Tools::AstDump.new, Lain::Tools::TestPattern.new, Lain::Tools::AstSearch.new,
           Lain::Tools::FileSymbols.new]
        end
      end
    end
  end
end
