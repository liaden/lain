# frozen_string_literal: true

require "async"
require "digest"
require "json"

module Lain
  module Approval
    # The phone's approval surface. It publishes the agenda of what waits on a
    # human, masked by {Remote::Agenda::View}, through the chat's registration
    # to the relay the daemon runs, and routes each answer the daemon pushes
    # back through the agenda to the owner that would take it at the desk. A
    # phone is a human, so its answers carry `:human` authority, at the asking
    # rung like the terminal's, and name the device that gave them.
    #
    # The relay is optional equipment: one the daemon does not run, or that
    # dies, costs this surface and nothing else, and the session journal says
    # so in a `capability_degraded` record. A daemon restart is not a death:
    # the registration reconnects and the surface publishes everything again.
    class RemoteSurface
      SURFACE = "remote"
      CAPABILITY = :remote_surface
      DEFAULT_POLL_INTERVAL = 0.25
      RUNNING = "running"
      NO_DAEMON = "no daemon to publish through"
      RELAY_STATE = "the daemon's phone relay is %<state>s; %<trace>s says why"

      # How the phone learns an answer was refused: the reason heads the item's
      # own text, since the wire has no reply to an answer the relay accepted.
      REFUSED = "your last answer was refused: %<reason>s"

      # A connection the registration is replacing; what it dropped is published again on reconnect.
      DROPPED = [Core::Died, Core::Client::Stopped].freeze

      # The daemon stamps every item with the registration's session, whatever the item says.
      UNSTAMPED = ""

      # The relay is gone, so nothing this surface publishes can reach a phone.
      class Unserved < Error; end

      # A chat that is ending must not wait on a relay that stopped answering.
      RETRACT_BUDGET = 1.0

      # A phone answer the desk beat: the phone was told it landed, so this line is its only trace.
      LOST_TYPE = "remote_answer_lost"

      # The unreadable-gate item's own text names a journal path, and no answer
      # from a phone can fix it, so the phone is told only where it is fixed.
      DESK_ONLY = "a gate journal cannot be read, so the gates waiting in it are not listed; " \
                  "fix it at the desk, where `lain epic queue` names the file"
      DESK_ONLY_REFUSAL = "this item can only be fixed at the desk"

      # The View masks secrets but not the layout of this box, which an owner's error may name.
      PATH_MASK = "<a path at the desk>"

      # An absolute or ~/ path of 2 segments or more; a bare "/" and "and/or" are words, not paths.
      PATH = %r{(?<![\w.])(?:~|/)[^\s'"`]*/[^\s'"`]*}

      # @param text [String] an error's message
      # @return [String] the text with every path in it replaced by {PATH_MASK}
      def self.unpathed(text) = text.gsub(PATH, PATH_MASK)

      # The surface a chat runs, when `remote relay:` is set and a human answers
      # it at all: over the agenda of this chat's parked calls, the project's
      # deferred gates and the chat's open questions.
      #
      # @param relay [String, nil] the `remote relay:` address, where nil leaves the phone surface off
      # @param paths [Paths]
      # @param root [String] the project root
      # @param registration [Daemon::Registration, Daemon::Registration::Null] the chat's place in the daemon
      # @param queue [Parked::Queue, nil] the chat's parked calls; nil when nobody answers the chat
      # @param replies [#waiting, #answer] the chat's open questions ({CLI::HumanReplies})
      # @param secrets [#to_a] the board's known secret values
      # @param journal [#<<] the session journal
      # @return [RemoteSurface, nil]
      def self.for(relay:, paths:, root:, registration:, queue:, replies:, secrets:, journal:)
        return unless relay && queue

        agenda = Remote::Agenda.new(queue:, gates: Remote::Agenda::Gates.new(paths:, root:), replies:)
        new(registration:, agenda:, secrets:, journal:, project: root.to_s,
            trace: Daemon::Launch.trace_path(paths:))
      end

      # @param registration [#call, #on] the chat's {Daemon::Registration}: publishes go out as its
      #   requests, and answers come back as its pushes
      # @param agenda [Remote::Agenda] what waits on a human, and where an answer goes
      # @param secrets [#to_a] the board's known secret values, which every published item is masked for
      # @param journal [#<<] where a degraded relay and a failed sweep are recorded
      # @param identity [Sensitivity::Secrets::Identity] the account, home and host values, shown as placeholders
      # @param poll_interval [Numeric] seconds between reads of the agenda
      # @param project [String] the project root every published item names, and every gate key is scoped to
      # @param trace [String] the daemon's trace, which says why its relay is unavailable
      def initialize(registration:, agenda:, secrets:, project:, trace:, journal: Channel::Null::INSTANCE,
                     identity: Sensitivity::Secrets::Identity.session, poll_interval: DEFAULT_POLL_INTERVAL)
        @registration = registration
        @project = project
        @trace = trace
        @agenda = agenda
        @secrets = secrets
        @identity = identity
        @journal = journal
        @poll_interval = poll_interval
        start_unpublished
      end

      # Runs for the conversation, in its own fiber, and returns once the relay is gone.
      #
      # @return [void]
      def watch
        @registration.on("answer") { |params| answered(params.first) }
        @registration.on(Daemon::Registration::RECONNECTED) { @resync_due = true }
        sweep while serving?
      rescue Unserved => e
        degrade(e)
      ensure
        retract unless @degraded
      end

      private

      def start_unpublished
        @cursor = 0
        @published = {}
        @refused = {}
        @reported = Set.new
        @agenda_lock = Mutex.new
        @asked = false
        @resync_due = true
      end

      def serving?
        start_over if @resync_due
        !@degraded
      end

      def sweep
        publish
        Async::Task.current.sleep(@poll_interval)
      end

      # The daemon that answers now holds none of what this surface published before. No answer at
      # all before the first sweep is no daemon; after it, a registration still reconnecting.
      def start_over
        state = relay_state
        return if state.nil? && @asked

        @asked = true
        @resync_due = false
        return degrade(Unserved.new(state ? relay_off(state) : NO_DAEMON)) unless state == RUNNING

        @cursor = 0
        @published.clear
      end

      def relay_off(state) = format(RELAY_STATE, state:, trace: @trace)

      def relay_state
        @registration.call("daemon.info")&.fetch("relay", nil)
      rescue *DROPPED
        nil
      end

      def answered(wired)
        take(Remote::Wire::Answer.from_wire(wired))
      rescue Remote::Wire::Malformed => e
        fault(e)
      end

      # An owner may refuse with any error, and a raise here would end the
      # fiber every later answer arrives on.
      def take(answer)
        won = @agenda_lock.synchronize { @agenda.answer(answer.id, answer_of(answer), surface: surface_of(answer)) }
        lost(answer) unless won
      rescue StandardError => e
        fault(e)
        @refused[answer.id] = e.message
      end

      def lost(answer)
        @journal << { "type" => LOST_TYPE, "id" => answer.id, "device" => answer.device }
      end

      def surface_of(answer) = answer.device ? "#{SURFACE}:#{answer.device}" : SURFACE

      def answer_of(answer)
        case answer
        when Remote::Wire::Answer::Call then answer.verdict
        when Remote::Wire::Answer::Gate then answer.verdicts.to_h
        else text_of(answer)
        end
      end

      def text_of(answer)
        text = [answer.option, answer.text].compact.join("\n")
        raise ArgumentError, "an answer to a question needs an option or some text" if text.empty?

        text
      end

      # Every view is made before anything is sent, so a secrets source that
      # raises stops the sweep with nothing unmasked published, and the next
      # sweep starts from the same cursor.
      def publish
        cursor, added, settled = @agenda_lock.synchronize { @agenda.delta_since(@cursor) }
        views = added.to_h do |item|
          [item, Remote::Agenda::View.of(phone_face(item), secrets: @secrets, identity: @identity)]
        end.compact
        settle(settled.select { @published.key?(_1) })
        views.each { |item, view| show(item, view) }
        @cursor = cursor
        republish_refused
      rescue Unserved
        raise
      rescue *DROPPED
        nil
      rescue StandardError => e
        fault(e)
      end

      def settle(ids)
        return if ids.empty?

        send_delta(settled: ids)
        ids.each { @published.delete(_1) }
      end

      # Published before the send: the phone can show the item before its reply lands, and a stop in
      # between must still take it back. A refused first showing is unrecorded, so it is never settled
      # for nothing.
      def show(item, view)
        held = @published.key?(item.id)
        @published[item.id] = item
        send_delta(added: [wired(view)], keys: gate_keys(item))
      rescue Core::Client::Refused => e
        @published.delete(item.id) unless held
        fault(e)
      end

      def republish_refused
        refused = @refused.slice(*@published.keys)
        @refused.clear
        refused.each do |id, reason|
          face = annotated(phone_face(@published.fetch(id)), reason)
          view = Remote::Agenda::View.of(face, secrets: @secrets, identity: @identity)
          view && show(@published.fetch(id), view)
        end
      end

      def phone_face(item) = desk_only?(item) ? item.with(question: DESK_ONLY) : item

      def desk_only?(item) = item.is_a?(Remote::Agenda::GateQuestion) && item.epic.empty?

      def annotated(item, reason)
        reason = desk_only?(item) ? DESK_ONLY_REFUSAL : self.class.unpathed(reason)
        field = item.is_a?(Remote::Agenda::ParkedCall) ? :why : :question
        item.with(field => [format(REFUSED, reason:), item.public_send(field)].reject(&:empty?).join("\n"))
      end

      # A refusal from a relay that has since died is the relay's end, not one item's fault.
      def send_delta(added: [], settled: [], keys: {})
        @registration.call("agenda.publish", Remote::Wire::Delta.new(cursor: 0, added:, settled:).to_wire, keys)
      rescue Core::Client::Refused
        state = relay_state
        raise Unserved, relay_off(state) if state && state != RUNNING

        raise
      end

      # Keyed by the artifact revisions a yes approves, read off the unmasked item: 2 chats in 1 project
      # then share a wave whatever secrets each knows, and a wave with any row asked again is a new item,
      # so an answer given to the old one cannot approve a revision the phone never showed.
      def gate_keys(item)
        return {} unless item.is_a?(Remote::Agenda::GateQuestion) && !desk_only?(item)

        { item.id => Digest::SHA256.hexdigest([@project, item.epic, item.stage, item.digests.sort].inspect) }
      end

      def wired(view)
        common = { id: view.id, requester: view.requester, asked_at: view.asked_at.to_i,
                   session: UNSTAMPED, project: @project }
        case view
        when Remote::Agenda::ParkedCall
          Remote::Wire::Item::ParkedCall.new(**common, tool: view.tool, input: JSON.generate(view.input),
                                                       cwd: view.cwd, why: view.why, postponed: false)
        when Remote::Agenda::GateQuestion
          Remote::Wire::Item::GateQuestion.new(**common, epic: view.epic, stage: view.stage, issues: view.issues,
                                                         question: view.question)
        else
          Remote::Wire::Item::Question.new(**common, question: view.question, options: view.options)
        end
      end

      # Items this chat published would otherwise wait on the phone after the chat is gone.
      def retract
        Async::Task.current.with_timeout(RETRACT_BUDGET) { settle(@published.keys) }
      rescue StandardError
        nil
      end

      def degrade(error)
        return if @degraded

        @degraded = true
        @journal << Telemetry::CapabilityDegraded.new(capability: CAPABILITY, requirer: self.class.name,
                                                      provider: error.message)
      end

      # Once per distinct failure, so a fault that repeats every sweep is one record.
      def fault(error)
        text = "#{error.class}: #{error.message}"
        return unless @reported.add?(text)

        @journal << { "type" => Parked::QueueSurface::FAULT_TYPE, "surface" => SURFACE, "error" => text }
      end
    end
  end
end
