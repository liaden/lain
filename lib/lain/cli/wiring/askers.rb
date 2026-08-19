# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # Who may ask the human, and where an arrival goes. One object because
      # the three are one fact: an asker that announces to a queue nobody
      # registered can be answered by nobody, and a registration without the
      # announcement is an agent parked in silence.
      #
      # It is a SECOND responsibility rather than more of {Wiring}'s own --
      # "assemble a chat" does not include "route an answer back to whoever
      # asked" -- and that is why it was extracted when {Wiring} had one line of
      # ClassLength headroom left. It spent a while NESTED in wiring.rb, because
      # T11 scoped the CLI half of the question chunk to that file; a file of its
      # own is where the same rule points once that scope is spent, and it is
      # where its four siblings under `wiring/` already live. Nothing named it
      # differently: the constant is unchanged.
      class Askers
        # An asker and the thing that stops it being routable. Both, because
        # retention in the {Tools::AskHuman::Directory} runs from `register`
        # to `deregister` and NOTHING else releases it: whoever owns an
        # asker's lifetime has to hold the registration, which the run's own
        # asker never needs (it dies with the run) and a child's lease does.
        Enrolled = Data.define(:asker, :registration)

        # What a desktop notification may spend on WHO is asking: dunstify
        # renders `"#{agent} asks"` as the title, and an asker's identity in
        # the record is a 71-character correlation digest -- not a title. The
        # same 19 the TTY drain and {Frontend::Neovim::InboxView} already clamp
        # their sender column to, so the three surfaces name an asker the same
        # way.
        NAME_WIDTH = 19

        attr_reader :questions, :directory

        # The seam wired to nothing: its arrivals reach a queue nobody drains
        # and a desktop that is not there, and its directory routes only its
        # own askers. It exists for the direct-construction seams the specs
        # drive -- {ToolsetBuild::NoSwitchboard}'s precedent, one class over --
        # and it is NOT a sanctioned production state: a child enrolled here
        # parks a human question nobody can see, which is the exact failure the
        # arrival seam exists to prevent. The exe always passes the run's own.
        def self.unwired
          new(notifier: Lain::Notify::Null.new, observer: Lain::Event::ChainWriter::Null.new)
        end

        # @param notifier [Lain::Notify] the desktop half of an arrival
        # @param observer [#call] the chronicle's -- Q and A are exactly the
        #   events a Timeline walk can never find, so a missing observer is
        #   silent record loss; required for that reason, not defaulted.
        def initialize(notifier:, observer:)
          @notifier = notifier
          @observer = observer
          @questions = Async::Queue.new
          @directory = Lain::Tools::AskHuman::Directory.new
        end

        # One agent's asker: announced to the human on every ask, and
        # registered so an answer NAMING one of its sets routes back to it.
        # Both locals are read inside the notify thunk at CALL time -- the
        # late-binding idiom this file uses twice more -- so the tool, the
        # names it opens, and the announcement it fans out cannot come apart.
        #
        # `registration` is declared before the thunk that reads it because
        # the two cannot be built in one order: the registration needs the
        # asker, and the asker's announcement needs the registration. A name
        # first mentioned INSIDE the block parses as a method call and raises
        # there instead, which is the whole reason the nil is written out.
        #
        # @param parent [Timeline, #call] the live parent-Timeline handle ({AskHuman}'s
        #   own `parent:`) -- a Timeline or a thunk reading one, since the toolset is
        #   built before the Agent; the shared Store and the asker's identity both
        #   ride on it
        # @param agent [String, nil] what a human is told is asking, when this
        #   asker has a name worth reading (the main chat's, a child's role).
        #   Per-asker, never per-seam: one name for every arrival is the
        #   hardcoded `"lain"` this widening removed. Absent, the correlation
        #   stands in, clamped -- see {#desktop_name}.
        #
        #   It is handed to the ASKER as well as to the announcement (T15), so
        #   it rides the Q event ({Tools::AskHuman::ASKED_BY}) and the surfaces
        #   that never see an arrival -- {Frontend::Neovim::InboxView} folds the
        #   record stream -- name the asker the same way this one does.
        def enrol(parent, agent: nil)
          registration = nil
          asker = Lain::Tools::AskHuman::Notifying.new(
            parent:, observer: @observer, agent:,
            notify: ->(question) { announce(question, asker:, registration:, agent:) }
          )
          registration = @directory.register(asker)
          Enrolled.new(asker:, registration:)
        end

        private

        # I5, widened (T11): ONE arrival, three surfaces. What rides the queue
        # is the inbox item itself, not the question's bytes -- the digest an
        # answer must cite, and the asker that asked it -- and both are read
        # HERE, at the instant the Q event was written, because that is the
        # only instant they are true. Read at drain time instead, "who asked"
        # is whoever asked most recently and the digest is not recoverable at
        # all.
        #
        # The name is opened on the registration BEFORE the arrival goes out,
        # and that ordering is the whole of the routing: {Directory} answers
        # only names some registration has heard of, so a question announced
        # to a human who could then answer it faster than it was registered
        # would be refused as unknown.
        def announce(question, asker:, registration:, agent:)
          item = HumanReplies::InboxItem.asked(question, asker.last_question, agent:)
          registration.asked(item.digest)
          @questions.enqueue(item)
          @notifier.question(agent: desktop_name(agent, item), text: question)
        end

        # Who the desktop is told is asking: this asker's own name when it has
        # one, else the correlation that identifies it everywhere else. Both
        # arms clamp, and they clamp in ONE place, so the bound holds for a
        # name nobody thought to keep short as much as for a digest.
        def desktop_name(agent, item)
          (Blankness.blank?(agent) ? item.from.to_s : agent.to_s)[0, NAME_WIDTH]
        end
      end
    end
  end
end
