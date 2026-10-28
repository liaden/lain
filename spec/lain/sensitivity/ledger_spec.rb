# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Ledger do
  subject(:ledger) { described_class.new }

  def regions(content) = Lain::Sensitivity::Regions.detect(content)

  # Long, random and base64-shaped, so every one of them is a region for a
  # reason about ENTROPY that no threshold under discussion is near. An example
  # about the LEDGER must never fail for a reason about the detector.
  let(:first) { "kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3" }
  let(:second) { "qW3eR7tY1uI5oP9aS2dF6gH0jK4lZ8xC3vB7nM1qW5eR9tY2" }
  let(:third) { "zX7cV2bN8mQ4wE1rT6yU0iO5pA9sD3fG7hJ2kL8zX4cV6bN0" }

  let(:path) { "/repo/.env" }
  let(:other_path) { "/repo/config/.env.local" }

  let(:two) { regions("API_KEY=#{first}\nSESSION_SECRET=#{second}\n") }
  let(:three) { regions("API_KEY=#{first}\nSESSION_SECRET=#{second}\nAUTH_TOKEN=#{third}\n") }
  let(:one) { regions("API_KEY=#{first}\n") }

  # The fixtures are the premise of nearly every example below, so a detector
  # change that stopped yielding one region per assignment would silently turn
  # most of this file green-and-empty rather than red.
  it "builds fixtures of two, three and one region" do
    expect([two.size, three.size, one.size]).to eq([2, 3, 1])
  end

  it "builds fixtures whose regions are the values alone" do
    expect(two.map { _1.bytes.dup.force_encoding(Encoding::UTF_8) }).to eq([first, second])
  end

  describe "#outstanding" do
    it "reports every region of a path it has never seen" do
      expect(ledger.outstanding(path, two)).to eq(two)
    end

    it "reports nothing once both regions are released" do
      ledger.release(path, two)

      expect(ledger.outstanding(path, two)).to be_empty
    end

    it "reports nothing when the same bytes are read a third time" do
      ledger.release(path, two)
      ledger.outstanding(path, two)

      expect(ledger.outstanding(path, two)).to be_empty
    end

    it "reports exactly the new region when a third key is added" do
      ledger.release(path, two)

      expect(ledger.outstanding(path, three).map(&:digest)).to eq([three.last.digest])
    end

    it "reports nothing when a released region is deleted" do
      ledger.release(path, two)

      expect(ledger.outstanding(path, one)).to be_empty
    end

    it "drops the deleted region's digest rather than remembering it" do
      ledger.release(path, two)
      ledger.outstanding(path, one)

      expect(ledger.released(path)).to eq([one.first.digest])
    end

    it "asks again about a deleted region that comes back" do
      ledger.release(path, two)
      ledger.outstanding(path, one)

      expect(ledger.outstanding(path, two).map(&:digest)).to eq([two.last.digest])
    end

    it "answers the regions in the order it was given them" do
      expect(ledger.outstanding(path, three)).to eq(three)
    end

    it "answers a frozen list" do
      expect(ledger.outstanding(path, two)).to be_frozen
    end

    it "leaves a path with no regions holding nothing" do
      ledger.release(path, two)
      ledger.outstanding(path, [])

      expect(ledger).to be_empty
    end

    it "is idempotent when re-asked with the same regions" do
      ledger.release(path, two)
      answers = Array.new(3) { [ledger.outstanding(path, two).size, ledger.released(path).size] }

      expect(answers).to eq([[0, 2], [0, 2], [0, 2]])
    end

    # Sibling reads of one file are concurrent FIBERS ({Tools::ReadFile#parallel_safe?}),
    # so a partial reader can interleave with a complete one. `complete: false`
    # is what stops it costing the complete reader its releases.
    it "lets a partial read in another fiber cost the complete one nothing" do
      ledger.release(path, two)
      partial = Fiber.new { Fiber.yield(ledger.outstanding(path, one, complete: false)) }
      partial.resume

      expect(ledger.outstanding(path, two)).to be_empty
    end

    # The mechanical half of the fiber-safety note in the class docstring: no
    # method here can yield between a read and its mutate, because none of them
    # does anything that yields at all. The one Monitor is the only lock, and a
    # same-thread fiber re-enters it.
    #
    # Only things that actually YIELD are named. An earlier edition also barred
    # `File.` and `.read`, which forbade a correct change -- `File.absolute_path?`
    # is a pure string predicate, and {Sensitivity::Rule} two files away uses
    # `File.basename` and `File.fnmatch?` exactly that way. A guard that fails a
    # refactor it has no opinion about is worse than no guard.
    it "has no yield point between a read and its mutate" do
      source = File.read(File.expand_path("../../../lib/lain/sensitivity/ledger.rb", __dir__))
      body = source.lines.grep_v(/^\s*#/).join

      expect(body).not_to match(/Fiber|Thread|Mutex|Ractor|Async|ConditionVariable|SizedQueue|
                                 \bsleep\b|\bgets\b|\bsystem\b|`|%x|\.pop\b|IO\./x)
    end

    it "reconciles only the path it was asked about" do
      ledger.release(path, two)
      ledger.release(other_path, two)
      ledger.outstanding(path, [])

      expect(ledger.released(other_path).size).to eq(2)
    end
  end

  # Traversable exactly ONCE, which is what an Enumerator over a streamed read
  # is. CLAUDE.md's style section tells implementers to return an Enumerator
  # rather than materialize an Array and calls `Enumerator::Lazy` free
  # streaming, so the masking arm -- the one that holds the bytes -- is the one
  # most likely to hand this over.
  def single_pass(items)
    Class.new do
      include Enumerable

      def initialize(items) = (@items = items)
      def each(&block) = @items.tap { @items = [] }.each(&block)
    end.new(items.dup)
  end

  # Reconciling is sound only over EVERY region in the file. Hand it a subset --
  # a size-capped detection, an offset read, a sibling fiber's partial -- and it
  # discards the releases for what it did not see, which on a capped read is an
  # approval treadmill forever, on exactly the large files where it hurts most.
  # `complete:` is {Session#record_read}'s own keyword for the same question, and
  # it defaults TRUE for the same reason its `complete:` does: reconciling when
  # you should not have costs a prompt, and not reconciling when you should have
  # leaves a deleted-then-restored secret released.
  describe "a read that saw only part of the file" do
    it "answers what is outstanding without discarding the rest" do
      ledger.release(path, two)
      ledger.outstanding(path, one, complete: false)

      expect(ledger.released(path)).to eq(two.map(&:digest).sort)
    end

    it "does not re-prompt an already-approved secret after a partial read" do
      ledger.release(path, two)
      ledger.outstanding(path, one, complete: false)

      expect(ledger.outstanding(path, two)).to be_empty
    end

    it "still reports an unreleased region it did see" do
      ledger.release(path, one)

      expect(ledger.outstanding(path, two, complete: false).map(&:digest)).to eq([two.last.digest])
    end

    it "reconciles by default, so forgetting the keyword fails closed" do
      ledger.release(path, two)
      ledger.outstanding(path, one)

      expect(ledger.released(path)).to eq([one.first.digest])
    end

    # {Session::ReadSet#record}'s check, and its ordering: strict-boolean FIRST,
    # ahead of any mutation. Read for truthiness instead and `complete: "false"`
    # reconciles -- the unsafe direction, silently.
    it "refuses a non-boolean completeness rather than reading it for truthiness" do
      expect { ledger.outstanding(path, two, complete: "false") }
        .to raise_error(ArgumentError, /complete must be true or false/)
    end

    # The value has to be TRUTHY to discriminate: `complete: nil` is skipped by
    # the reconcile's own `if` whatever the check's position, so it cannot tell
    # a check-then-mutate from a mutate-then-check. `"false"` is the string that
    # {Session::ReadSet#record}'s comment names, and it is the one that bites.
    it "refuses a truthy non-boolean before it mutates anything" do
      ledger.release(path, two)
      expect { ledger.outstanding(path, one, complete: "false") }.to raise_error(ArgumentError)

      expect(ledger.released(path).size).to eq(2)
    end

    # The check sits ahead of `regions.to_a`, and that ordering is the fail-open
    # arriving through the rescue path: drain a single-pass collection before
    # raising and a caller that rescues and retries hands over an EMPTY list, so
    # `outstanding` answers `[]` -- nothing masked, everything released.
    it "does not consume a single-pass regions collection on a refusal" do
      collection = single_pass(two)
      expect { ledger.outstanding(path, collection, complete: "yes") }.to raise_error(ArgumentError)

      expect(ledger.outstanding(path, collection)).to eq(two)
    end

    # The falsy-guard sweep, pinned: `complete:` is the only boolean keyword in
    # the public surface, so the `complete: nil` blind spot that hid a
    # mutate-then-check cannot reappear somewhere else unnoticed. The one other
    # keyword, `authority:`, is a Symbol checked against a closed set.
    it "has exactly one boolean keyword in the public surface" do
      kinds = %i[key keyreq]
      keywords = described_class.public_instance_methods(false).flat_map do |name|
        described_class.instance_method(name).parameters.select { kinds.include?(_1.first) }
      end

      expect(keywords).to contain_exactly(%i[key complete], %i[key authority])
    end
  end

  describe "a regions collection that can be walked only once" do
    # Walking it twice answered `[]` -- "nothing outstanding" -- which releases
    # every secret in the file with nobody asked. The one direction a release
    # ledger must never fail in.
    it "reports every region of a single-pass Enumerable" do
      expect(ledger.outstanding(path, single_pass(two))).to eq(two)
    end

    it "reports every region of a lazy enumerator" do
      expect(ledger.outstanding(path, two.lazy)).to eq(two)
    end

    # A Lazy in gave a Lazy out, which has no `#empty?` -- the masking arm's
    # natural call.
    it "answers an Array whatever it was given" do
      expect(ledger.outstanding(path, two.lazy)).to be_an(Array)
    end

    it "releases every region of a single-pass Enumerable" do
      ledger.release(path, single_pass(two))

      expect(ledger.released(path).size).to eq(2)
    end

    # A lazy release is the sharper case: `Enumerator::Lazy#map` answers a Lazy,
    # which has no `#empty?`, so a release that did not materialize first would
    # raise on the size guard rather than record the human's answer.
    it "releases every region of a lazy enumerator" do
      ledger.release(path, two.lazy)

      expect(ledger.released(path)).to eq(two.map(&:digest).sort)
    end

    it "records nothing for an empty lazy release" do
      ledger.release(path, [].lazy)

      expect(ledger).to be_empty
    end

    it "reconciles against a single-pass Enumerable rather than emptying the path" do
      ledger.release(path, two)
      ledger.outstanding(path, single_pass(two))

      expect(ledger.released(path).size).to eq(2)
    end

    it "is unchanged for a re-enumerable Enumerator" do
      enum = Enumerator.new { |yielder| two.each { |region| yielder << region } }

      expect(ledger.outstanding(path, enum)).to eq(two)
    end
  end

  describe "keying by path as well as digest" do
    let(:header) { "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" }
    let(:mine) { regions("#{header}.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvZWwifQ.dBjftJeZ4CVPmNkYWxyZ0FiQ2RFZg") }
    let(:theirs) { regions("#{header}.eyJzdWIiOiI5ODc2NTQzMjEwIiwibmFtZSI6IkFubmUifQ.QsvyzHGnPXmZqRt7YnBvUXdFcw") }
    let(:shared_header) { mine.map(&:digest) & theirs.map(&:digest) }

    it "reports a digest released for one file as outstanding for another" do
      ledger.release(path, two)

      expect(ledger.outstanding(other_path, two)).to eq(two)
    end

    # A BARE JWT is three regions -- `.` is not in the token charset -- and the
    # header of every HS256 token is the identical byte string, so releasing one
    # JWT pre-releases that header at that path. Per-path keying is the whole
    # containment, and this is the example that says so. Bare and not `token:
    # <jwt>`, which the assignment shape takes as one region, dots and all.
    it "contains a shared JWT header segment to the path it was released at" do
      expect(shared_header).to eq([mine.first.digest])

      ledger.release(path, mine)

      expect(ledger.outstanding(other_path, theirs)).to eq(theirs)
    end

    it "still releases the shared header at the path it was released at" do
      ledger.release(path, mine)

      expect(ledger.outstanding(path, mine)).to be_empty
    end

    it "treats a Pathname and its String as one file" do
      ledger.release(Pathname.new(path), two)

      expect(ledger.outstanding(path, two)).to be_empty
    end

    # `nil.to_s` is `""`, so a path this class merely coerced would bucket every
    # unnamed read together -- the cross-file leak, arriving through a type error
    # in silence. Loud, for {Sensitivity#text!}'s reason.
    it "refuses a path that names no file" do
      [nil, 42, [], :"/repo/.env"].each do |bad|
        expect { ledger.outstanding(bad, two) }.to raise_error(ArgumentError, /String or answer #to_path/)
      end
    end

    it "refuses to release against such a path" do
      expect { ledger.release(nil, two) }.to raise_error(ArgumentError, /String or answer #to_path/)
    end

    it "accepts anything answering #to_path, not only a Pathname" do
      File.open(__FILE__) { |file| ledger.release(file, two) }

      expect(ledger.released(__FILE__).size).to eq(2)
    end

    # The blank String is the very bucket the type check exists to prevent, and
    # it is a String, so it sailed through. {Session#named!} refuses a blank
    # spelling for the identical reason: `nil.to_s` would otherwise put `""` in
    # the set, after which a thing that does not exist reads as decided.
    #
    # A RELATIVE path is the same failure one step out, and the sharper one:
    # `config/.env` under a parent's cwd and under a child worktree's cwd are two
    # different files behind one key -- a release that travels, which is the
    # direction this boundary must never fail in. Normalizing cannot fix it here,
    # because the ledger is per-RUN and reaches every child through the board
    # thunk, so there is no single cwd to normalize against. Refusing needs none.
    it "refuses a blank path" do
      ["", " ", "\t\n"].each do |blank|
        expect { ledger.outstanding(blank, two) }.to raise_error(ArgumentError, /must be absolute/)
      end
    end

    it "refuses a relative path rather than merging two files behind one key" do
      expect { ledger.release("config/.env", two) }.to raise_error(ArgumentError, /must be absolute/)
    end

    it "refuses a relative path on every entry point, not only the writing one" do
      %i[outstanding release].each do |message|
        expect { ledger.public_send(message, ".env", two) }.to raise_error(ArgumentError, /must be absolute/)
      end
      expect { ledger.released(".env") }.to raise_error(ArgumentError, /must be absolute/)
      expect { ledger.released?(".env", "blake3:abc") }.to raise_error(ArgumentError, /must be absolute/)
    end

    it "refuses a relative Pathname too, so the duck does not route around the guard" do
      expect { ledger.outstanding(Pathname.new("config/.env"), two) }.to raise_error(ArgumentError, /must be absolute/)
    end

    it "names the offending path, so a caller can see what it forgot to resolve" do
      expect { ledger.outstanding("config/.env", two) }.to raise_error(ArgumentError, %r{"config/\.env"})
    end

    # Fail-closed and worth stating: the key is the bytes, so the same name in
    # two encodings is two keys and costs one extra prompt. It cannot merge.
    it "splits a same-bytes path in another encoding" do
      unicode = "/repo/café/.env"
      ledger.release(unicode, two)

      expect(ledger.outstanding(unicode.dup.force_encoding(Encoding::ASCII_8BIT), two)).to eq(two)
    end

    # Every alternate spelling of one absolute file is its own key. Fail-closed
    # -- it costs a prompt and can never merge two files.
    it "splits alternate spellings of one absolute file" do
      ledger.release(path, two)
      spellings = ["/repo/./.env", "/repo/sub/../.env", "/repo//.env", "/repo/.env/"]

      expect(spellings.map { ledger.outstanding(_1, two).size }).to eq([2, 2, 2, 2])
    end
  end

  describe "#release" do
    it "answers itself, so a caller may chain" do
      expect(ledger.release(path, two)).to be(ledger)
    end

    it "adds to what a path already holds rather than replacing it" do
      ledger.release(path, one)
      ledger.release(path, [three.last])

      expect(ledger.released(path).size).to eq(2)
    end

    it "records nothing for an empty release" do
      ledger.release(path, [])

      expect(ledger).to be_empty
    end

    it "is idempotent for the same region twice" do
      2.times { ledger.release(path, two) }

      expect(ledger.released(path).size).to eq(2)
    end
  end

  describe "#released?" do
    it "answers false for a digest never released" do
      expect(ledger.released?(path, two.first.digest)).to be(false)
    end

    it "answers true for a digest released at that path" do
      ledger.release(path, two)

      expect(ledger.released?(path, two.first.digest)).to be(true)
    end

    it "answers false for the same digest at another path" do
      ledger.release(path, two)

      expect(ledger.released?(other_path, two.first.digest)).to be(false)
    end
  end

  describe "#released_digests" do
    it "answers an empty set before anything is released" do
      expect(ledger.released_digests).to eq(Set.new)
    end

    it "answers every human-released digest over every path" do
      ledger.release(path, one, authority: :human).release(other_path, three.drop(1), authority: :human)

      expect(ledger.released_digests).to eq(Set[*one.map(&:digest), *three.drop(1).map(&:digest)])
    end

    it "leaves out an automatic release, which still serves the read" do
      ledger.release(path, two)

      expect(ledger.released_digests).to be_empty
      expect(ledger.outstanding(path, two)).to be_empty
    end

    it "keeps a digest a human released even when a surface released it automatically too" do
      ledger.release(path, one, authority: :human).release(path, two)

      expect(ledger.released_digests).to eq(one.to_set(&:digest))
    end

    it "answers only the paths the block accepts" do
      ledger.release(path, one, authority: :human).release(other_path, three.drop(1), authority: :human)

      expect(ledger.released_digests { _1 == path }).to eq(one.to_set(&:digest))
    end

    it "forgets a human release the file no longer holds" do
      ledger.release(path, two, authority: :human)
      ledger.outstanding(path, one)

      expect(ledger.released_digests).to eq(one.to_set(&:digest))
    end

    it "refuses an authority no surface settles with" do
      expect { ledger.release(path, one, authority: :model) }.to raise_error(ArgumentError, /authority/)
    end

    it "answers a frozen copy, so a caller cannot release through it" do
      answer = ledger.release(path, one, authority: :human).released_digests

      expect { answer << two.last.digest }.to raise_error(FrozenError)
    end

    it "holds the digests of a 2-region release and no byte of either value" do
      ledger.release(path, two, authority: :human)
      held = ledger.instance_variables.reject { _1 == :@monitor }.map { ledger.instance_variable_get(_1) }
      kept = Marshal.dump(held)

      expect(ledger.released_digests).to eq(two.to_set(&:digest))
      expect([first, second].select { kept.include?(_1) }).to be_empty
    end
  end

  describe "#released" do
    it "answers an empty list for a path it has never seen" do
      expect(ledger.released(path)).to eq([])
    end

    it "answers the digests sorted, so a consumer does not vary with arrival order" do
      ledger.release(path, two)

      expect(ledger.released(path)).to eq(two.map(&:digest).sort)
    end

    it "answers a frozen list" do
      expect(ledger.release(path, two).released(path)).to be_frozen
    end
  end

  describe "one ledger per run" do
    # One arm masks against the ledger and another prompts against it, through
    # different files in different waves. Two half-wirings give two ledgers and
    # a release control that silently releases nothing, so sharing is a property
    # with an example rather than a diagram.
    it "shows one arm's release to another arm holding the same ledger" do
      masking = ledger
      approving = ledger
      approving.release(path, two)

      expect(masking.outstanding(path, two)).to be_empty
    end

    # The anti-vacuity guard for the wiring assertion above: `both answer the
    # same object` is only a test while two distinct ledgers are distinguishable.
    # The planned assertion is `be(...)`, which no `==` can make vacuous, so this
    # guards the weaker relation and the example below it carries the weight.
    it "does not make two distinct ledgers equal" do
      expect(described_class.new).not_to eq(described_class.new)
    end

    it "inherits identity ==, so eq and equal? are one relation here" do
      expect(described_class.instance_method(:==).owner).to eq(BasicObject)
    end

    it "keeps two ledgers independent, which is what a second one would cost" do
      ledger.release(path, two)

      expect(described_class.new.outstanding(path, two)).to eq(two)
    end
  end

  describe "the session boundary" do
    it "starts with nothing released" do
      expect(ledger).to be_empty
    end

    it "holds nothing after a release is reconciled away" do
      ledger.release(path, two)
      ledger.outstanding(path, [])

      expect(ledger).to be_empty
    end

    # Session-scoped is the security property, not an unfinished feature:
    # persisting "yes, send .env.local" across runs is exactly the answer
    # a remembered-answer store refuses to keep. A
    # persistence path is what its absence has to be spec'd as.
    it "offers no way to persist or reload itself" do
      expect(described_class.public_instance_methods(false).sort)
        .to eq(%i[decline declined? empty? forget lapse lapsed? outstanding release released released?
                  released_digests])
    end

    # The instance surface alone is not the guard: a `def self.load` would walk
    # straight past it, and so would a class-level cache pretending to be one
    # ledger per run.
    it "offers no class-level constructor or store beyond .new" do
      expect([described_class.methods(false), described_class.instance_variables,
              described_class.class_variables]).to eq([[], [], []])
    end

    it "gives each instance its own store" do
      store = ->(led) { led.instance_variable_get(:@released) }

      expect(store.call(described_class.new)).not_to be(store.call(described_class.new))
    end

    it "writes nothing to disk when releasing" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          ledger.release(path, two)
          ledger.outstanding(path, two)
        end

        expect(Dir.children(dir)).to eq([])
      end
    end
  end

  describe "declines and lapses" do
    it "remembers a decline by path and region" do
      ledger.decline(path, two)

      expect(two.map { ledger.declined?(path, _1) }).to eq([true, true])
    end

    it "keeps a decline at one path from answering for the same bytes at another" do
      ledger.decline(path, one)

      expect(ledger.declined?(other_path, one.first)).to be(false)
    end

    it "does not count a decline as a release" do
      ledger.decline(path, one)

      expect(ledger.outstanding(path, one)).to eq(one)
    end

    it "keeps a lapse apart from a decline" do
      ledger.decline(path, two)
      ledger.lapse(path, one)

      expect([ledger.lapsed?(path, two.first), ledger.lapsed?(path, two.last)]).to eq([true, false])
    end

    it "refuses a relative path" do
      expect { ledger.decline("env", one) }.to raise_error(ArgumentError, /absolute/)
    end

    it "forgets one path's declines and lapses and says how many regions that cleared" do
      ledger.decline(path, two)
      ledger.lapse(path, one)
      ledger.decline(other_path, one)

      expect(ledger.forget(path)).to eq(2)
    end

    it "answers false for a forgotten region and still holds the other path" do
      ledger.decline(path, two)
      ledger.lapse(path, two)
      ledger.decline(other_path, one)
      ledger.forget(path)

      expect([ledger.declined?(path, two.first), ledger.lapsed?(path, two.first),
              ledger.declined?(other_path, one.first)]).to eq([false, false, true])
    end

    it "counts a lapse on one region and a decline on another as 2" do
      ledger.lapse(path, [two.first])
      ledger.decline(path, [two.last])

      expect(ledger.forget(path)).to eq(2)
    end

    it "counts a lapse alone" do
      ledger.lapse(path, two)

      expect(ledger.forget(path)).to eq(2)
    end

    it "counts a region both lapsed and declined once" do
      ledger.lapse(path, one)
      ledger.decline(path, one)

      expect(ledger.forget(path)).to eq(1)
    end

    it "enters its one monitor for every reader and writer" do
      monitor = Monitor.new
      entries = 0
      allow(monitor).to(receive(:synchronize).and_wrap_original do |original, &block|
        (entries += 1) && original.call(&block)
      end)
      allow(Monitor).to receive(:new).and_return(monitor)
      guarded = described_class.new
      calls = [-> { guarded.outstanding(path, one) }, -> { guarded.release(path, one) },
               -> { guarded.released?(path, one.first.digest) }, -> { guarded.released(path) },
               -> { guarded.released_digests }, -> { guarded.empty? }, -> { guarded.decline(path, one) },
               -> { guarded.lapse(path, one) }, -> { guarded.declined?(path, one.first) },
               -> { guarded.lapsed?(path, one.first) }, -> { guarded.forget(path) }]

      entered = calls.map do |call|
        before = entries
        call.call
        entries > before
      end

      expect(entered).to all(be(true))
    end

    it "answers 0 for a path it holds nothing for" do
      expect(ledger.forget(path)).to eq(0)
    end

    it "keeps every decline made from parallel threads" do
      paths = Array.new(8) { "/repo/file#{_1}.env" }

      paths.map { |each| Thread.new { 50.times { ledger.decline(each, three) } } }.each(&:join)

      expect(paths.sum { ledger.forget(_1) }).to eq(24)
    end
  end

  describe "what it deliberately does not do" do
    # Detection is ~0.22ms/KB and linear, so a ledger that ran it would put a
    # size cap here rather than at the caller that holds the bytes.
    it "never runs the detector, so it never opens or reads a file" do
      given = two # detected HERE, before the spy, or the fixture's own call is counted
      allow(Lain::Sensitivity::Regions).to receive(:detect).and_call_original

      ledger.release(path, given)
      ledger.outstanding(path, given)

      expect(Lain::Sensitivity::Regions).not_to have_received(:detect)
    end

    # Depend on messages, not on types: the ledger sends `#digest` and nothing
    # else, which is what lets the masking arm hand it whatever it detected.
    it "asks a region for its digest and nothing else" do
      region = instance_double(Lain::Sensitivity::Regions::Region, digest: "blake3:abc")

      ledger.release(path, [region])

      expect(ledger.released?(path, "blake3:abc")).to be(true)
    end

    # Deliberately mutable and deliberately NOT on the {Session}: the run owns
    # it, the Switchboard holds it beside the run's one queue and one policy.
    it "is not frozen, because it is the run's decisions and not a value" do
      expect(ledger).not_to be_frozen
    end
  end
end
