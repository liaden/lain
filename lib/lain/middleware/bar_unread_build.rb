# frozen_string_literal: true

require "delegate"

module Lain
  module Middleware
    # Holds a build for a human once the lineage ran a command lain could not
    # read. The sandbox withdraws a build tool's ports while that mark stands,
    # since the command may have planted what the build runs; without this
    # layer the build would just fail to fetch, with nothing saying why.
    #
    # It bars only a call the session's sandbox would really grant its ports
    # were the mark lifted, asked of the same {Confine::Profiles::Granting} the
    # sandbox asks, over stages resolved as the run resolves them; a call whose
    # words ask no build tool is let through before anything resolves. Under
    # `bypass`, or with nobody attending, no human can vouch, so the call is
    # refused here in words that name the command, as {TripwireStop} refuses.
    class BarUnreadBuild < Base
      RUNG = "unread_build"
      GUARDED_TOOL = "bash"

      BARRED = "%<command>s ran earlier in this lineage and lain could not read what it wrote, so %<tool>s gets " \
               "its network only once a human approves this call, which vouches for the project"
      REFUSED = "%<barred>s; %<why>s"
      BYPASS = "approval is bypass, so no human is asked: switch to /mode ask to approve it"
      UNATTENDED = "nobody attends this session to approve it"

      # The context a barred build is judged in: never automatically approved, and a human's allow vouches.
      class Barred < SimpleDelegator
        # @param context [Object] the call's own
        # @param fresh [#vouch!] the lineage
        # @param root [String] where the build runs
        # @param command [String] the unread command the human is shown, which is all their allow vouches for
        def initialize(context, fresh:, root:, command:)
          super(context)
          @fresh = fresh
          @root = root
          @command = command
        end

        def automatic_approval_barred? = true

        # The gate hands its ruling here before the call runs, so the vouch lands before the sandbox asks.
        #
        # @param ruling [Approval::Escalation::Ruling]
        # @return [self]
        def ruled(ruling)
          @fresh.vouch!(@root, command: @command) if ruling.allow? && ruling.human?
          inner = __getobj__
          inner.ruled(ruling) if inner.respond_to?(:ruled)
          self
        end
      end

      # @param fresh [#unread_command, #vouch!] the lineage the sandbox reads
      # @param granting [Confine::Profiles::Granting, Confine::Profiles::Granting::NONE] what the sandbox
      #   would grant a build
      # @param secrets [#for] the session's secret values, masked out of the command a reason names
      # @param journal [#<<] where a refusal lands as an `escalation` record
      # @param mode [#approval] the session's mode, read at each call because `/mode` flips it
      # @param attended [Boolean] whether a human is there to be asked at all
      # @param requester [Requester, nil] who a child's stack asks for; nil reads it off the context
      def initialize(fresh:, granting:, secrets:, journal:, mode: TripwireStop::NoMode, attended: true,
                     requester: nil)
        @fresh = fresh
        @granting = granting
        @secrets = secrets
        @journal = journal
        @mode = mode
        @attended = attended
        @requester = requester
        super()
        freeze
      end

      def call(env, &app)
        effect = ::Lain::Sensitivity::Policy.unwrapped(env.fetch(:effect))
        context = env[:context]
        root = guarded?(effect) && root_of(context)
        command = root && @fresh.unread_command(root)
        tool = command && granted_tool(env.fetch(:tool), effect, context)
        return downstream(env, &app) unless tool

        because = format(BARRED, command: shown(command, context), tool:)
        return refused(env, effect, because) unless held?

        downstream(env.merge(context: barred(context, because, root, command)), &app).merge(context:)
      end

      private

      def guarded?(effect) = effect.tool_call? && effect.name == GUARDED_TOOL

      def root_of(context) = ::Lain::Session.worker_env_of(context).checkout || @granting.root

      # The words are read first, since resolving every stage costs a bash call far more than its verdict.
      def granted_tool(tool, effect, context)
        return unless tool.respond_to?(:planned_request)
        return unless @granting.asks?(tool.planned_argvs(effect.input, context))

        request = tool.planned_request(effect.input, context, tool_use_id: effect.tool_use_id)
        @granting.build_grant_for(request, vouched: true)
      rescue Tool::InvalidInput
        nil
      end

      # An older record's stand-in is prose, not a command, so it is not set as one.
      def shown(command, context)
        return command if command == ::Lain::Shell::Executable::Fresh::UNNAMED

        "`#{::Lain::Sensitivity::TextMask.text(command, secrets: @secrets.for(context))}`"
      end

      def held? = @attended && TripwireStop::ASKING.include?(@mode.approval.name)

      def barred(context, because, root, command)
        noted = Approval::Escalation::Noted.new(context || Session::Null.instance,
                                                Approval::Parked::Queue::Reason.own(because))
        Barred.new(noted, fresh: @fresh, root:, command:)
      end

      def refused(env, effect, because)
        why = @attended ? BYPASS : UNATTENDED
        ruling = Approval::Escalation::Ruling.deny(rung: RUNG, because: format(REFUSED, barred: because, why:),
                                                   final: true, liftable: @attended)
        Telemetry::Escalation.write(@journal, ruling, effect, env[:context], requester: @requester)
        told = format(ruling.liftable? ? Gate::LIFTABLE : Gate::FINAL, name: effect.name.inspect, because: ruling.told)
        env.merge(result: Tool::Result.error(told))
      end
    end
  end
end
