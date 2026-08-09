# frozen_string_literal: true

# The partition VALUE and the strategy PORT, which ship together because
# neither is meaningful alone: a partition is what a strategy answers, and the
# port is the only statement of what makes an object one.
#
# `Partition::Strategy` has no spec file of its own on purpose -- it is a module
# inside `partition.rb`'s subtree with no state and four class methods, and the
# card that introduced it named this file as its home. Its group is below,
# named for it, so a reader searching for `Strategy` finds it here.
RSpec.describe Lain::Review::Partition do
  def hunk(path, added:, deleted:)
    lines = Array.new(deleted) { |i| "-old#{i}" } + Array.new(added) { |i| "+new#{i}" }
    Lain::Review::Hunk.new(path:, old_start: 1, old_count: deleted, new_start: 1,
                           new_count: added, lines:)
  end

  def file(path, added: 1, deleted: 1, binary: false)
    hunks = binary ? [] : [hunk(path, added:, deleted:)]
    Lain::Review::Source::ChangedFile.new(old_path: path, new_path: path, binary:, hunks:)
  end

  def partition(label: "lib/a", files: [file("lib/a/one.rb")], **rest)
    described_class.new(label:, files:, **rest)
  end

  describe "#with, which is what /critique chunking packs through" do
    subject(:whole) { partition(label: "lib/a", files: %w[a.rb b.rb c.rb].map { |path| file(path) }) }

    # `Bounds#critique_chunks` calls exactly this, so a Partition that were a
    # plain duck rather than a Data would break chunking and nothing else.
    it "answers a new partition with the same label and the files it was handed" do
      narrowed = whole.with(files: [file("a.rb")])

      expect([narrowed.label, narrowed.files.map(&:path)]).to eq(["lib/a", ["a.rb"]])
    end

    it "leaves the original untouched, so a chunking walk cannot rewrite what it read" do
      whole.with(files: [])

      expect(whole.files.size).to eq(3)
    end

    it "freezes the files it was handed, so a copy is as shareable as the original" do
      narrowed = whole.with(files: [file("a.rb")])

      expect(Ractor.shareable?(narrowed)).to be(true)
    end
  end

  # `Changeset::CommitScope`'s guarantee, inherited: `Marks#reconcile` reads
  # `#base_ref` and `#hunks` together and prunes every key the changeset it is
  # given does not produce, so handing it a FILTERED group silently drops the
  # marks on everything the filter hid. The missing message is the fix.
  describe "a partition cannot be mistaken for a whole changeset" do
    it "does not answer #hunks" do
      expect(partition).not_to respond_to(:hunks)
    end

    it "does not answer #base_ref, which the reconciler reads before anything else" do
      expect(partition).not_to respond_to(:base_ref)
    end

    it "still reaches its hunks the honest way, through its files" do
      expect(partition.files.flat_map(&:hunks).size).to eq(1)
    end
  end

  describe "deep immutability" do
    it "is shareable, so no reachable mutable state remains" do
      expect(Ractor.shareable?(partition)).to be(true)
    end

    # A label reaches a `Bounds::TooLarge` message, which is journalled -- and
    # `Canonical.dump` raises on a String that is not validly UTF-8. Scrubbed
    # here, once, rather than at each of the three renderers.
    it "scrubs a label whose bytes are not valid UTF-8, since a refusal carrying one is journalled" do
      labelled = partition(label: "bad\xFF".b)

      expect(labelled.label).to be_valid_encoding
      expect(labelled.label).to eq("bad?")
    end

    it "freezes the files array it was handed rather than trusting the caller" do
      files = [file("a.rb")]

      expect { partition(files:) }.to change(files, :frozen?).from(false).to(true)
    end
  end

  # The core is `label` and `files`; everything a PARTICULAR strategy knows in
  # addition rides on `detail`, and the default one is the honest answer for a
  # strategy that has no accounting of its own: read it off the hunks.
  describe "the accounting a partition carries when its strategy supplies none" do
    subject(:detail) { partition.detail }

    let(:files) { [file("a.rb", added: 3, deleted: 2), file("b.rb", added: 1, deleted: 0)] }

    it "counts added lines off the hunks, never a number nobody reported" do
      expect(detail.added(files)).to eq(4)
    end

    it "counts deleted lines off the same hunks" do
      expect(detail.deleted(files)).to eq(2)
    end

    # The message a refusal names the group by. A strategy with nothing to add
    # answers the label unchanged -- a directory path says what it is already.
    it "names a group by its bare label, having nothing to add to it" do
      expect(detail.named("lib/a")).to eq("lib/a")
    end

    # A binary file carries no hunks at all, so it contributes to neither sum --
    # which is exactly why the count exists: `+0 -0` on an all-binary group
    # reads as "nothing changed".
    it "counts the binary files its line sums could not read" do
      binaries = [file("logo.png", binary: true), file("a.rb")]

      expect([detail.added(binaries), detail.binaries(binaries)]).to eq([1, 1])
    end

    it "is shareable, being state-free" do
      expect(Ractor.shareable?(detail)).to be(true)
    end
  end

  # The registry, and the property A3 builds its scope resolution on: one
  # instance per strategy, so a resolved scope can be compared or cached.
  describe "the registry of shipped strategies" do
    subject(:registry) { described_class::STRATEGIES }

    it "answers the same Hash however often it is asked" do
      expect(registry).to equal(described_class::STRATEGIES)
    end

    # The defect this replaced minted a fresh instance per call, so two
    # constants built from the registry were neither `equal?` nor `==` -- these
    # are plain classes with identity equality, so the miss is silent.
    it "answers the same strategy OBJECT for one name, so two readers cannot disagree" do
      expect(registry.fetch(:commits)).to equal(described_class::STRATEGIES.fetch(:commits))
    end

    it "registers each strategy under its own name, frozen" do
      expect(registry.keys).to match_array(%i[cumulative commits by_directory])
      expect(registry.values).to all(be_frozen)
      expect(registry.to_h { |name, strategy| [name, strategy.name.to_sym] })
        .to eq(registry.keys.to_h { |name| [name, name] })
    end
  end

  # What the THREE default sites read instead of each spelling `cumulative`
  # themselves (`CLI::Review#default_scope`, `CLI::Command::Review#default_scope`,
  # `Tools::RequestReview::SCOPE`). The point is not the word: it is that the
  # absent flag names a REGISTERED strategy, so a default nothing serves is a
  # load-time `KeyError` rather than an `UnknownScope` the first human to omit
  # the flag discovers.
  describe "the scope an absent flag means" do
    it "is a name the registry answers for" do
      expect(described_class::STRATEGIES).to have_key(described_class::DEFAULT_SCOPE.to_sym)
    end

    it "is the flat view's own spelling, read off the strategy rather than restated" do
      expect(described_class::DEFAULT_SCOPE).to eq(described_class::Whole.new.name)
    end
  end

  # ---------------------------------------------------------------------------
  # The port.
  # ---------------------------------------------------------------------------
  describe Lain::Review::Partition::Strategy do
    # A candidate built from a Hash of message => body, so each example below
    # differs from a COMPLETE strategy in exactly one way and the difference is
    # the thing under test.
    def candidate(**bodies)
      Class.new do
        bodies.each { |message, body| define_method(message, &body) }
      end.new
    end

    def complete
      candidate(name: -> { "x" }, partition: ->(_changeset) { [] },
                advice: -> { "do it another way" }, supports?: ->(_source) { true })
    end

    it "declares one shape per message, deeply frozen so no caller can rewrite it" do
      expect(described_class::MESSAGES.values).to all(be_frozen)
      expect(described_class::MESSAGES.values.flatten(1)).to all(be_frozen)
    end

    it "passes a candidate answering the whole port" do
      expect { described_class.check!(complete) }.not_to raise_error
    end

    it "passes every strategy this chunk ships, which is what makes the port real" do
      shipped = [Lain::Review::Partition::Whole.new, Lain::Review::Partition::ByDirectory.new]

      expect { shipped.each { |strategy| described_class.check!(strategy) } }.not_to raise_error
    end

    # Not a spec-only claim: the registry runs this over each strategy as it
    # builds it, so a strategy that stopped answering the port raises while
    # `lain` is being required rather than the first time a scope is resolved.
    it "holds every REGISTERED strategy to the port, which the registry checks at build" do
      expect { Lain::Review::Partition::STRATEGIES.each_value { |s| described_class.check!(s) } }
        .not_to raise_error
    end

    it "refuses a candidate that does not answer #advice, naming the message" do
      incomplete = candidate(name: -> { "x" }, partition: ->(_changeset) { [] }, supports?: ->(_source) { true })

      expect { described_class.check!(incomplete) }
        .to raise_error(described_class::Incomplete, /does not answer advice/)
    end

    it "refuses a candidate whose #partition takes no arguments, naming the arity" do
      wrong = candidate(name: -> { "x" }, partition: -> {}, advice: -> { "" }, supports?: ->(_source) { true })

      expect { described_class.check!(wrong) }
        .to raise_error(described_class::Incomplete, /partition with 0 argument\(s\) where the port declares 1/)
    end

    # Present, but not callable the way the port needs -- told apart from
    # "you forgot to write this", which is what it used to read as.
    it "refuses a candidate answering #name only privately" do
      hidden = Class.new do
        def partition(_changeset) = []
        def advice = ""
        def supports?(_source) = true

        private

        def name = "x"
      end.new

      expect { described_class.check!(hidden) }
        .to raise_error(described_class::Incomplete, /only privately/)
    end

    it "names the whole port in its refusal, so a reader is not told one message at a time" do
      expect { described_class.check!(Object.new) }
        .to raise_error(described_class::Incomplete, /name, partition, advice, supports\?/)
    end
  end
end
