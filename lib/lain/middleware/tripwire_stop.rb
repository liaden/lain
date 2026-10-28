# frozen_string_literal: true

require "delegate"

module Lain
  module Middleware
    # Refuses every call from a requester the tripwire stopped, and holds a
    # paused main agent's calls for a human. It acts from the next call on: a
    # call already running when the tripwire tripped is left to finish.
    #
    # A paused call is handed down rather than refused, barred from automatic
    # approval, so the ladder's asking rung parks it whatever rung would have
    # approved it. Under `bypass`, or with nobody attending, no human can be
    # asked, so the call is refused here instead.
    #
    # A trip can land while a call is judged or parked, so {#over} reads the
    # standing again once the gate's ladder has approved it.
    #
    # It sits ahead of {RememberedDenials} for that one's reason: a refusal
    # here must reach calls the gate would never have asked about.
    class TripwireStop < Base
      RUNG = "tripwire"

      # The approval levels whose ladder ends in a rung that asks a human.
      ASKING = %i[ask auto].freeze

      STOPPED = "the tripwire stopped %<requester>s; a call already running when it tripped was left to finish, " \
                "and every call from the next call on is refused"
      PAUSED = "the tripwire paused the main agent after %<tripped>s tripped it, and no human approved this call; " \
               "a call already running when it tripped was left to finish. %<resume>s"
      RESUME = "To resume, switch approval to ask, and a human is asked about each of main's calls"
      UNATTENDED = "Nobody attends this session, so main's calls stay refused"
      HELD = "the tripwire paused the main agent after %<tripped>s tripped it, so a human decides each of its calls"

      # A run with no approval level asks nobody, so a pause there refuses.
      module NoMode
        def self.approval = Mode::Approval.for(:bypass)
      end

      # The context a paused call is judged in.
      class Paused < SimpleDelegator
        def automatic_approval_barred? = true
      end

      # The gate policy, read again once its ladder approves.
      class Rechecked
        def initialize(policy, layer)
          @policy = Gate::Callable.of(policy)
          @layer = layer
          freeze
        end

        def rule(effect, context)
          ruling = @policy.rule(effect, context)
          ruling.allow? ? @layer.rechecked(ruling, effect, context) : ruling
        end

        def call(effect, context) = rule(effect, context).allow?
      end

      # @param stops [#standing, #first_tripped] who the tripwire has stopped
      # @param journal [#<<] where each refusal lands as an `escalation` record
      # @param mode [#approval] the session's mode, read at each call because `/mode` flips it
      # @param attended [Boolean] whether a human is there to be asked at all
      # @param requester [Requester, nil] who a child's stack asks for; nil reads
      #   it off the context, as the queue does
      def initialize(stops:, journal:, mode: NoMode, attended: true, requester: nil)
        @stops = stops
        @journal = journal
        @mode = mode
        @attended = attended
        @requester = requester
        super()
        freeze
      end

      def call(env, &app)
        effect = ::Lain::Sensitivity::Policy.unwrapped(env.fetch(:effect))
        return downstream(env, &app) unless effect.tool_call?

        requester = Telemetry::Escalation.requester_of(env[:context], @requester)
        standing = @stops.standing(requester)
        return downstream(env, &app) if standing == Tripwire::Stops::FREE
        return downstream(paused(env), &app).merge(context: env[:context]) if held?(standing)

        env.merge(result: Tool::Result.error(told(refusal(effect, requester, standing), effect)))
      end

      # @param policy [#rule, #call] what the gate asks, whose approve is read again here
      # @return [Rechecked]
      def over(policy) = Rechecked.new(policy, self)

      # @param ruling [Approval::Escalation::Ruling] the ladder's approve
      # @param effect [Effect::ToolCall] the call it approved
      # @param context [Object, nil] the context it was judged in
      # @return [Approval::Escalation::Ruling] it, or a refusal if the requester stands stopped,
      #   or paused with no human behind the approve
      def rechecked(ruling, effect, context)
        requester = Telemetry::Escalation.requester_of(context, @requester)
        standing = @stops.standing(requester)
        return ruling if standing == Tripwire::Stops::FREE || (standing == Tripwire::Stops::PAUSED && ruling.human?)

        refusal(effect, requester, standing)
      end

      private

      def held?(standing) = standing == Tripwire::Stops::PAUSED && @attended && ASKING.include?(@mode.approval.name)

      def paused(env)
        effect = env.fetch(:effect)
        noted = Approval::Escalation::Noted.new(env[:context] || Session::Null.instance,
                                                Approval::Parked::Queue::Reason.own(format(HELD, tripped:)))
        env.merge(effect: effect.approval? ? effect : Effect::Approval.new(effect:), context: Paused.new(noted))
      end

      def refusal(effect, requester, standing)
        because = if standing == Tripwire::Stops::STOPPED then format(STOPPED, requester:)
                  else format(PAUSED, tripped:, resume: @attended ? RESUME : UNATTENDED)
                  end
        liftable = @attended && standing == Tripwire::Stops::PAUSED
        Approval::Escalation::Ruling.deny(rung: RUNG, because:, final: true, liftable:).tap do |ruling|
          Telemetry::Escalation.write(@journal, ruling, effect, nil, requester:)
        end
      end

      # In the gate's own words for the same ruling.
      def told(ruling, effect)
        format(ruling.liftable? ? Gate::LIFTABLE : Gate::FINAL, name: effect.name.inspect, because: ruling.told)
      end

      def tripped = @stops.first_tripped
    end
  end
end
