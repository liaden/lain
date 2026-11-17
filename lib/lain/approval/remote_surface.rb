# frozen_string_literal: true

require "async"
require "json"
require "securerandom"

module Lain
  module Approval
    # The phone's approval surface. It publishes the agenda of what waits on a
    # human to the relay `lain up` runs, masked by {Remote::Agenda::View}, and
    # routes each answer a paired phone sends back through the agenda to the
    # owner that would take it at the desk. A phone is a human, so its answers
    # carry `:human` authority, at the asking rung like the terminal's, and name
    # the device that gave them.
    #
    # The relay is optional equipment: one that is not there, or dies, costs
    # this surface and nothing else, and the session journal says so in a
    # `capability_degraded` record.
    class RemoteSurface
      SURFACE = "remote"
      CAPABILITY = :remote_surface
      DEFAULT_POLL_INTERVAL = 0.25

      # A phone that is looking at the app needs no buzz, so a short wait is the desk's to end.
      DEFAULT_BUZZ_AFTER = 60

      # How the phone learns an answer was refused: the reason heads the item's
      # own text, since the wire has no reply to an answer the relay accepted.
      REFUSED = "your last answer was refused: %<reason>s"

      # Whatever ends the wire ends this surface; anything else is one sweep's fault.
      ENDS = [Core::Died, Core::Client::Stopped, Core::Client::HandshakeTimeout, Core::Client::VersionMismatch,
              Core::Transport::Unix::Unreachable, Core::Transport::Unix::Untrusted, Remote::Wire::Malformed].freeze

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

      # One socket per project, in a directory of its own, because the relay
      # confines its writes to the directory its socket is in.
      #
      # @param paths [Paths]
      # @param root [String] the project root
      # @return [String] where the relay `lain up` starts for this project listens for lain
      def self.socket(paths:, root:)
        File.join(paths.runtime_dir, "remote-#{paths.project_hash(root)}", "relay.sock")
      end

      # The surface a chat runs, when `remote relay:` is set and a human answers
      # it at all: over the agenda of this chat's parked calls, the project's
      # deferred gates and the chat's open questions.
      #
      # @param relay [String, nil] the `remote relay:` address, where nil leaves the phone surface off
      # @param ntfy [String, nil] the `remote ntfy:` topic URL a long-waiting item is announced on
      # @param paths [Paths]
      # @param root [String] the project root
      # @param queue [Parked::Queue, nil] the chat's parked calls; nil when nobody answers the chat
      # @param replies [#waiting, #answer] the chat's open questions ({CLI::HumanReplies})
      # @param secrets [#to_a] the board's known secret values
      # @param journal [#<<] the session journal
      # @return [RemoteSurface, nil]
      def self.for(relay:, ntfy:, paths:, root:, queue:, replies:, secrets:, journal:)
        return unless relay && queue

        agenda = Remote::Agenda.new(queue:, gates: Remote::Agenda::Gates.new(paths:, root:), replies:)
        new(transport: Core::Transport::Unix.new(socket(paths:, root:)), agenda:, secrets:, journal:,
            ntfy: announcer(ntfy))
      end

      def self.announcer(url) = url ? Remote::Ntfy.new(url:) : Remote::Ntfy::Null::INSTANCE
      private_class_method :announcer

      # @param transport [#start, #stop] the relay's Unix socket ({Core::Transport::Unix})
      # @param agenda [Remote::Agenda] what waits on a human, and where an answer goes
      # @param secrets [#to_a] the board's known secret values, which every published item is masked for
      # @param journal [#<<] where a degraded relay and a failed sweep are recorded
      # @param poll_interval [Numeric] seconds between reads of the agenda
      # @param prefix [String] marks this chat's ids on a relay other chats may publish to
      # @param ntfy [#notify] announces an item that has waited {buzz_after} seconds
      # @param clock [#now] what the wait is measured by
      # @param buzz_after [Numeric] seconds an item waits before it is announced
      def initialize(transport:, agenda:, secrets:, journal: Channel::Null::INSTANCE,
                     poll_interval: DEFAULT_POLL_INTERVAL, prefix: SecureRandom.hex(4),
                     ntfy: Remote::Ntfy::Null::INSTANCE, clock: Time, buzz_after: DEFAULT_BUZZ_AFTER)
        @transport = transport
        @agenda = agenda
        @secrets = secrets
        @journal = journal
        @poll_interval = poll_interval
        @prefix = "#{prefix}-"
        @ntfy = ntfy
        @clock = clock
        @buzz_after = buzz_after
        @waiting = {}
        @cursor = 0
        @published = {}
        @refused = {}
        @reported = Set.new
        @agenda_lock = Mutex.new
      end

      # @return [#notify] what announces an item that has waited too long
      attr_reader :ntfy

      # Runs for the conversation, in its own fiber, and returns once the relay is gone.
      #
      # @return [void]
      def watch
        client = Core::Client.start(transport: @transport)
        answering = Async { follow_answers(client) }
        @announcing = Async::Barrier.new
        while answering.running?
          publish(client)
          Async::Task.current.sleep(@poll_interval)
        end
      rescue *ENDS => e
        degrade(e)
      ensure
        answering&.stop
        @announcing&.stop
        retract(client) if client && !@degraded
        client&.stop
      end

      private

      def follow_answers(client)
        cursor = Remote::Wire::Cursor.new(cursor: 0, epoch: nil)
        loop do
          page = Remote::Wire::AnswersPage.from_wire(client.call("answers.next", [cursor.to_wire]))
          page.answers.select { ours?(_1) }.each { take(_1) }
          cursor = Remote::Wire::Cursor.new(cursor: page.cursor, epoch: page.epoch)
        end
      rescue *ENDS => e
        degrade(e)
      end

      def ours?(answer) = answer.id.start_with?(@prefix)

      # An owner may refuse with any error, and a raise here would end the
      # fiber every later answer arrives on.
      def take(answer)
        id = answer.id.delete_prefix(@prefix)
        won = @agenda_lock.synchronize { @agenda.answer(id, answer_of(answer), surface: surface_of(answer)) }
        lost(answer) unless won
      rescue StandardError => e
        fault(e)
        @refused[id] = e.message
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
      def publish(client)
        cursor, added, settled = @agenda_lock.synchronize { @agenda.delta_since(@cursor) }
        views = added.to_h { [_1, Remote::Agenda::View.of(phone_face(_1), secrets: @secrets)] }.compact
        settle(client, settled.select { @published.key?(_1) })
        views.each { |item, view| show(client, item, view) }
        @cursor = cursor
        republish_refused(client)
        announce_overdue
      rescue *ENDS
        raise
      rescue StandardError => e
        fault(e)
      end

      def settle(client, ids)
        return if ids.empty?

        send_delta(client, settled: ids.map { wire_id(_1) })
        ids.each do |id|
          @published.delete(id)
          @waiting.delete(id)
        end
      end

      def show(client, item, view)
        send_delta(client, added: [wired(view)])
        @waiting[item.id] = view unless @published.key?(item.id)
        @published[item.id] = item
      rescue Core::Client::Refused => e
        fault(e)
      end

      def republish_refused(client)
        refused = @refused.slice(*@published.keys)
        @refused.clear
        refused.each do |id, reason|
          view = Remote::Agenda::View.of(annotated(phone_face(@published.fetch(id)), reason), secrets: @secrets)
          view && show(client, @published.fetch(id), view)
        end
      end

      # Dropped before the POST, so a topic that is down is one failure and not one per sweep.
      def announce_overdue
        now = @clock.now
        @waiting.select { |_, view| now - view.asked_at >= @buzz_after }.each do |id, view|
          @waiting.delete(id)
          announce(view.with(id: wire_id(view.id)))
        end
      end

      def announce(view)
        @announcing.async do
          @ntfy.notify(view)
        rescue StandardError => e
          fault(e)
        end
      end

      def phone_face(item) = desk_only?(item) ? item.with(question: DESK_ONLY) : item

      def desk_only?(item) = item.is_a?(Remote::Agenda::GateQuestion) && item.epic.empty?

      def annotated(item, reason)
        reason = desk_only?(item) ? DESK_ONLY_REFUSAL : self.class.unpathed(reason)
        field = item.is_a?(Remote::Agenda::ParkedCall) ? :why : :question
        item.with(field => [format(REFUSED, reason:), item.public_send(field)].reject(&:empty?).join("\n"))
      end

      def send_delta(client, added: [], settled: [])
        client.call("agenda.publish", [Remote::Wire::Delta.new(cursor: 0, added:, settled:).to_wire])
      end

      def wire_id(id) = "#{@prefix}#{id}"

      def wired(view)
        common = { id: wire_id(view.id), requester: view.requester, asked_at: view.asked_at.to_i }
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
      def retract(client)
        Async::Task.current.with_timeout(RETRACT_BUDGET) { settle(client, @published.keys) }
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
