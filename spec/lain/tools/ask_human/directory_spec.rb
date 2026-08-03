# frozen_string_literal: true

require "async"

# T8: an answer NAMES a question set (its Q event's digest), and once more than
# one asker can hold a pending set -- a subagent asking the human beside its
# parent -- something has to know WHICH asker owns the name. That is the whole
# of this object: {Lain::Event::Projection#pending} stays the authority on what
# is pending, and this answers only who owns it.
RSpec.describe Lain::Tools::AskHuman::Directory do
  let(:store) { Lain::Store.new }
  let(:directory) { described_class.new }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

  def build_asker
    parent = Lain::Timeline.empty(store:)
                           .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    Lain::Tools::AskHuman.new(parent:)
  end

  # One registered asker holding one pending set, wired the way the world that
  # is coming wires it: ask, then name the set the ask returned.
  def asking(asker, question)
    registration = directory.register(asker)
    pending = asker.ask(question)
    registration.asked(pending.digest)
    [registration, pending]
  end

  # ---- Scenario: an answer reaches the asker that asked ---------------------

  it "routes an answer to the asker that asked it, leaving the other untouched" do
    Sync do
      one = build_asker
      two = build_asker
      _first_registration, first = asking(one, "which file?")
      _second_registration, second = asking(two, "which port?")

      answer = directory.reply("config.rb", first.digest)

      expect(first.await).to eq("config.rb")
      expect(answer.body.fetch("answer")).to eq("config.rb")
      expect(one.last_answer).to equal(answer)
      expect(second.resolved?).to be(false)
      expect(two.pending?).to be(true)
      expect(two.last_answer).to be_nil
    end
  end

  # ---- Scenario: an unknown digest is refused, not guessed ------------------

  # Not guessed means not PROBED either: a registered asker is never handed a
  # name it did not open, on the chance that it turns out to hold it.
  it "refuses a digest no registered asker holds, naming it, and answers nobody" do
    Sync do
      asker = build_asker
      allow(asker).to receive(:reply).and_call_original
      _registration, pending = asking(asker, "which file?")

      expect { directory.reply("nobody asked this", "sha256:absent") }
        .to raise_error(Lain::Tools::AskHuman::NoPendingQuestion, /sha256:absent/)
      expect(asker).not_to have_received(:reply)
      expect(pending.resolved?).to be(false)
      expect(asker.pending?).to be(true)
      expect(asker.last_answer).to be_nil
    end
  end

  # ---- Scenario: a resolved set is no longer routable -----------------------

  # The refusal is the registration's own, so the asker is not reached at all: a
  # second answer for a set already delivered is a coordination bug, and the
  # Store must be left exactly as the first answer left it.
  it "refuses a second answer for a set it already routed, without touching any asker" do
    Sync do
      asker = build_asker
      allow(asker).to receive(:reply).and_call_original
      _registration, pending = asking(asker, "which file?")
      directory.reply("config.rb", pending.digest)
      after_first = store.size

      expect { directory.reply("config.rb, again", pending.digest) }
        .to raise_error(Lain::Promise::AlreadyResolved, /#{pending.digest}/)
      expect(asker).to have_received(:reply).once
      expect(store.size).to eq(after_first)
    end
  end

  # ---- Scenario: a deregistered asker's questions are no longer routable ----

  # Deregistration is this object's whole lifecycle mechanism -- what the
  # supervisor lease that already reaps an actor sends when the actor is gone.
  # It withdraws the ROUTING only: the asker itself is untouched and still
  # holds its set, because a directory that answered questions on behalf of a
  # dead agent would be worse than one that refuses.
  it "refuses an answer for a deregistered asker, naming the digest and reaching no asker" do
    Sync do
      asker = build_asker
      allow(asker).to receive(:reply).and_call_original
      registration, pending = asking(asker, "which file?")

      registration.deregister

      expect { directory.reply("config.rb", pending.digest) }
        .to raise_error(Lain::Tools::AskHuman::NoPendingQuestion, /#{pending.digest}/)
      expect(asker).not_to have_received(:reply)
      expect(asker.pending?).to be(true)
    end
  end

  # ---- What deregistration costs: growth bounded by registration lifetime ---

  # An answered name is kept as a TOMBSTONE so a second answer is refused as
  # already-answered rather than as unknown -- and a tombstone the registration
  # outlives is a map that grows with the SESSION instead of with the fleet.
  # The names live inside the registration for exactly this reason: #forget
  # drops it whole, so there is nothing left behind to leak.
  describe "#forget (what a lease sends when the actor is reaped)" do
    it "drops every name the registration holds, answered ones included" do
      Sync do
        asker = build_asker
        registration = directory.register(asker)
        3.times do |n|
          pending = asker.ask("question #{n}")
          registration.asked(pending.digest)
          directory.reply("answer #{n}", pending.digest)
        end
        expect(directory.size).to eq(3)

        registration.deregister

        expect(directory.size).to eq(0)
      end
    end

    # Deliberate, not a fallout: once the asker is gone there is nothing left
    # to have answered anything, so "I have no record of this name" is the
    # honest refusal and "you already answered it" would be a claim about an
    # object nothing can reach.
    it "reports a set it already answered as unknown once its asker is deregistered" do
      Sync do
        asker = build_asker
        registration, pending = asking(asker, "which file?")
        directory.reply("config.rb", pending.digest)

        registration.deregister

        expect { directory.reply("config.rb, again", pending.digest) }
          .to raise_error(Lain::Tools::AskHuman::NoPendingQuestion, /#{pending.digest}/)
      end
    end
  end

  # ---- The door: a name is a digest, and a mistake is named there -----------

  # `#asked` is the ONLY way a name enters the map, so the mistake it has to
  # catch is the one that would otherwise sit in it forever: handing over the
  # promise (or the Q event) instead of the name it wears. Both answer
  # `#digest`, so both would key the map with something no answer can ever
  # match -- and the reply would then refuse a set that IS outstanding.
  it "refuses a name that is not a digest, at the door" do
    Sync do
      asker = build_asker
      registration = directory.register(asker)
      pending = asker.ask("which file?")

      expect { registration.asked(pending) }
        .to raise_error(ArgumentError, /pending\.digest/)
      expect(directory.size).to eq(0)
      expect { directory.reply("config.rb", pending.digest) }
        .to raise_error(Lain::Tools::AskHuman::NoPendingQuestion)
    end
  end

  # ---- Scenario (added): a withdrawn set stops being routable ---------------

  # An unwound sync gate (Ctrl-C, a gate's timeout) withdraws the set inside the
  # asker without telling anyone, so a digest can stop being answerable while
  # the directory still routes it. The refusal is read by a HUMAN at a `human>`
  # prompt -- the way in is a stale `/inbox` line -- so it must say what
  # happened and that nothing they typed was lost. {Outstanding::WITHDRAWN} is
  # already that sentence; routing by digest must not degrade it into
  # "this asker holds no question set at all".
  it "refuses a withdrawn set with the sentence a human at the reply prompt can act on" do
    Sync do |task|
      asker = build_asker
      registration = directory.register(asker)
      expect do
        task.with_timeout(0.01) { asker.call({ "question" => "which db?" }, invocation) }
      end.to raise_error(Async::TimeoutError)
      withdrawn = asker.last_question.digest
      registration.asked(withdrawn)
      after_ask = store.size

      expect { directory.reply("too late", withdrawn) }
        .to raise_error(Lain::Tools::AskHuman::NoPendingQuestion) do |error|
          expect(error.message).to include(withdrawn)
          expect(error.message).to include(Lain::Tools::AskHuman::Outstanding::WITHDRAWN)
        end
      expect(store.size).to eq(after_ask)
    end
  end

  # ---- Scenario: the null directory satisfies the same duck -----------------

  describe Lain::Tools::AskHuman::Directory::Null do
    it "answers the same messages and routes nothing" do
      Sync do
        asker = build_asker
        registration = described_class.register(asker)
        pending = asker.ask("which file?")

        expect(registration.asked(pending.digest)).to eq(pending.digest)
        expect { described_class.reply("config.rb", pending.digest) }
          .to raise_error(Lain::Tools::AskHuman::NoPendingQuestion, /#{pending.digest}/)
        expect(pending.resolved?).to be(false)
        expect(registration.deregister).to be_nil
        expect(described_class.forget(registration)).to equal(registration)
        expect(described_class.size).to eq(0)
      end
    end

    # Every message the real one answers, answered here -- BOTH objects, so no
    # caller can write `if directory` and none can be handed a registration it
    # has to check for. Mechanical rather than a list kept by hand: a message
    # added to either real object fails this until the null grows it too.
    it "answers every message the real directory and registration do" do
      real = Lain::Tools::AskHuman::Directory
      expect(real.public_instance_methods(false) - described_class.public_methods(false)).to be_empty
      expect(real::Registration.public_instance_methods(false) -
             described_class.register(nil).public_methods(false)).to be_empty
      expect(described_class.unanswerable("sha256:x")).to eq(real.unanswerable("sha256:x"))
    end
  end
end
