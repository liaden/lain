# frozen_string_literal: true

module Lain
  module CLI
    module Exe
      # WHERE a shell command becomes a process -- the {Lain::Exec} seam's two
      # selectable backends, and the image the container one starts from. A
      # declarer of their own on {SurfaceFlags}' rule: two flags naming one idea
      # are an object, and the Thor class has no Metrics/ClassLength headroom to
      # spend on a second `method_option`.
      #
      # ⚠️ NEITHER FLAG IS A SAFETY CONTROL. `--exec docker` changes which
      # toolchain a command finds, never what the command is permitted to do: the
      # container runs as the calling user on a read-write mount of the project,
      # and {Lain::Exec::Docker}'s class doc says so at length. Tier-3 approval is
      # the boundary for every value of this flag. Help text that started
      # promising confinement would be the defect, not the feature.
      module ExecFlags
        # Constants rather than inline strings, because the two `method_option`
        # calls plus their prose ran this declarer past Metrics/MethodLength --
        # and the sentences are the part a reader of `--help` actually reads.
        BACKEND = "How a shell command becomes a process " \
                  "(#{Lain::CLI::ExecBackend::BACKENDS.join(", ")}): in this process, or one `docker run --rm` " \
                  "per command with the project mounted. It selects a toolchain, never a confinement -- tier-3 " \
                  "approval is still the boundary. `docker` takes one argv, so a pipeline it cannot " \
                  "reconstruct falls back to the model's own string, run as `sh -c` INSIDE the container; " \
                  "crosses a fixed set (LAIN_*, LANG/LC_*, TZ, TERM, NO_COLOR, CI) by NAME on the command " \
                  "line, values kept off it; and is refused at launch for a missing client, before a session " \
                  "record exists -- but the daemon is not probed until the first command, so one that is down " \
                  "surfaces then".freeze

        IMAGE = "The image `--exec docker` starts each container from " \
                "(default #{Lain::Exec::Docker::DEFAULT_IMAGE}, which carries `sh` and little else -- name " \
                "your project's own)".freeze

        ARM_CONFINE = "Bash confinement (#{Lain::CLI::Arms::CONFINE.join(", ")}; " \
                      "default #{Lain::CLI::Arms::DEFAULT.confine}): workspace " \
                      "runs a command the judge, a rule or bypass approved in the workspace sandbox, reader runs " \
                      "it traced and unconfined; both run a read-only command in the reader sandbox, and a call you " \
                      "approve yourself runs traced and unconfined, except one that reads secrets: a plain y runs " \
                      "that one contained, without network, in the sandbox, though under workspace a build tool's " \
                      "fetch keeps its ports and the prompt names them, and only the network answer runs it " \
                      "unconfined".freeze
        BENCH_CONFINE = "How far bash is confined in each arm (#{Lain::Bench::CLI::CONFINES.join(", ")}; " \
                        "default #{Lain::Bench::CLI::DEFAULT_CONFINE}). " \
                        "reader runs a read-only command whose paths stay in the checkout in the reader sandbox; " \
                        "any other command runs traced and unconfined, or in the workspace sandbox under " \
                        "workspace. A command whose paths cannot be read is refused in a lease".freeze
        ARM_JUDGE_FACTS = "Bench arm: what the auto judge is told about a command " \
                          "(#{Lain::CLI::Arms::JUDGE_FACTS.join(", ")}; default #{Lain::CLI::Arms::DEFAULT.judge_facts})".freeze
        ARM_JUDGE_DENIALS = "Bench arm: what a judge's refusal does under auto approval: applied, handed to a human " \
                            "(escalate_only), or counted until #{Lain::Approval::DenialBreaker::IN_A_ROW} in a row " \
                            "or #{Lain::Approval::DenialBreaker::PER_SESSION} in a session stop the judge " \
                            "being asked about that requester (breaker) " \
                            "(#{Lain::CLI::Arms::JUDGE_DENIALS.join(", ")}; " \
                            "default #{Lain::CLI::Arms::DEFAULT.judge_denials})".freeze
        ARM_JUDGE_OPAQUE = "Bench arm: whether a command whose paths cannot be named goes to the auto judge, " \
                           "under the workspace sandbox and only when every program it runs resolves " \
                           "(#{Lain::CLI::Arms::JUDGE_OPAQUE.join(", ")}; " \
                           "default #{Lain::CLI::Arms::DEFAULT.judge_opaque})".freeze
        ARM_TRIPWIRE = "Binary identity tripwire (#{Lain::CLI::Arms::TRIPWIRE.join(", ")}; " \
                       "default #{Lain::CLI::Arms::DEFAULT.tripwire}). " \
                       "stop fails closed on the seeded signals, honest calls included: a stopped agent's next calls " \
                       "are refused, and a paused main's go to a human, or are refused when nobody can be asked; the " \
                       "rest stay observe-only".freeze
        ARM_ROUND_BUDGET = "What one tool round's results may cost together " \
                           "(#{Lain::CLI::Arms::ROUND_BUDGET.join(", ")}; default #{Lain::CLI::Arms::DEFAULT.round_budget})".freeze

        ARM_ROUND_DEDUP = "Answer a repeated tool result by naming the first " \
                          "(#{Lain::CLI::Arms::ROUND_DEDUP.join(", ")}; default #{Lain::CLI::Arms::DEFAULT.round_dedup})".freeze

        # @param thor [Class] the Thor class to declare on
        # @return [void]
        def self.declare(thor)
          thor.method_option :exec, type: :string, default: Lain::CLI::ExecBackend::DEFAULT, desc: BACKEND
          thor.method_option :exec_image, type: :string, banner: "IMAGE", desc: IMAGE
          thor.method_option :confine, type: :string, banner: "ARM", desc: ARM_CONFINE
          thor.method_option :judge_facts, type: :string, banner: "ARM", desc: ARM_JUDGE_FACTS
          thor.method_option :judge_denials, type: :string, banner: "ARM", desc: ARM_JUDGE_DENIALS
          thor.method_option :judge_opaque, type: :string, banner: "ARM", desc: ARM_JUDGE_OPAQUE
          thor.method_option :tripwire, type: :string, banner: "ARM", desc: ARM_TRIPWIRE
          thor.method_option :round_budget, type: :string, banner: "ARM", desc: ARM_ROUND_BUDGET
          thor.method_option :round_dedup, type: :string, banner: "ARM", desc: ARM_ROUND_DEDUP
        end

        # The launch-time half of the flag, in a module method rather than inline in
        # `#chat` on {ModelFlags}' rule -- and because four reads of the options hash
        # spent the last of that method's Metrics/AbcSize budget, which is the cop
        # asking for the object this module already is.
        #
        # Refused AHEAD of {Lain::CLI::ChatLaunch}, so an `--exec` name this box
        # cannot run costs the operator nothing: no project resolved, no journal
        # opened, no session file on disk. The backend it builds is DROPPED, which
        # is what makes `root: Dir.pwd` the honest value here -- the question asked
        # is "can this box run that flag?", never "what would it mount?". The
        # backend a run actually uses is resolved by
        # {Lain::CLI::Wiring::ToolsetBuild} from the resolved Project's root.
        #
        # @param options [Hash] the parsed chat flags
        # @option options [String] :exec the execution backend name
        # @option options [String] :exec_image the container image for a docker backend
        # @return [void]
        # @raise [Lain::Error] an unknown name, or docker with no client on PATH
        def self.refuse_unusable!(options)
          Lain::CLI::Arms.from(options)
          Lain::CLI::ExecBackend.resolve(options[:exec], image: options[:exec_image], root: Dir.pwd)
        end
      end
    end
  end
end
