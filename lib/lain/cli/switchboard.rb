# frozen_string_literal: true

module Lain
  module CLI
    # The live switches a session's commands flip (T14), lifted out of {Wiring}
    # because "which switches exist, and what they start as" is its own
    # responsibility (the Metrics trip said so: extract, do not loosen):
    #
    # * ONE {Approval::PolicySwitch} the Gate holds for the whole session --
    #   `/yolo` flips the delegate inside it, Gate stays construction-fixed.
    #   `--yolo` starts it on {Gate::ApproveAll} and wires NO queue; otherwise
    #   the {Approval::Queue} is both the initial policy and the parked list
    #   `/approve` drains ({#approvals} is nil under --yolo, so Wiring's
    #   callers keep their existing no-queue paths).
    # * ONE {Context::ModelSwitch} the main agent's Context reads at render
    #   time -- `/model` writes it, {#graft} installs it.
    #
    # Every switch journals its flips to the SAME journal approval decisions
    # land in: on a study bench "who flipped what, when" is evidence.
    class Switchboard
      attr_reader :approvals, :policy_switch, :model_switch

      # The wiring entry: resolves the journal the chronicle carries -- the
      # null device under --no-journal (the operator declined the record, not
      # the gate) -- then builds the switches over it, reading the surface
      # flags (`--yolo`, `--auto-approve`) off the CLI options itself.
      def self.for(chronicle:, options:, model:)
        journal = chronicle.telemetry_kwargs.fetch(:journal) { Journal.new(io: File.open(File::NULL, "ab")) }
        new(journal:, model:, yolo: options[:yolo])
      end

      # @param journal [#record] where flips and approval decisions land
      # @param yolo [Boolean] start approving everything, with no queue
      # @param model [String] the model in force until the first /model
      def initialize(journal:, yolo:, model:)
        @approvals = yolo ? nil : Approval::Queue.new(journal:)
        @policy_switch = Approval::PolicySwitch.new(@approvals || Effect::Handler::Gate::ApproveAll.new, journal:)
        @model_switch = Context::ModelSwitch.new(model, journal:)
      end

      # The main agent's context grafted over the live model slot -- the ONLY
      # context that gets it; a subagent renders its role's own.
      def graft(context) = context.with_model(@model_switch)

      # The session's approval gate over `inner`: the Gate holds this board's
      # ONE policy switch, so /yolo flips reach it while the Gate itself stays
      # construction-fixed.
      def gate(inner:) = Effect::Handler::Gate.new(policy: policy_switch, inner:)

      # This board's contribution to the {Command::Surface}: the two switches,
      # plus /approve's inline drain prompt over the SAME conductor-routed
      # reader the Repl's watch surface uses (see Repl::ApprovalSurfaces#approval_surface's WHY).
      def surface_kwargs(conductor:, tty:)
        { policy_switch:, model_switch:, approval_prompt: prompt(conductor:, tty:) }
      end

      private

      def prompt(conductor:, tty:)
        Frontend::ApprovalPolicy.new(reader: ->(question) { conductor.read_reply(tty, question) })
      end
    end
  end
end
