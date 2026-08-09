# frozen_string_literal: true

RSpec.describe Lain::Review::LazyFile do
  def hunk(path: "a.rb", lines: [" one", "-two", "+TWO"])
    Lain::Review::Hunk.new(path:, old_start: 1, old_count: 3, new_start: 1, new_count: 3, lines:)
  end

  def changed_file(old_path: "a.rb", new_path: "a.rb", hunks: [hunk], binary: false)
    Lain::Review::Source::ChangedFile.new(old_path:, new_path:, hunks:, binary:)
  end

  # The chunker's CALLS are counted, not a memo ivar: "produced once" is a claim
  # about how often the work ran, and an ivar that happens to be set says nothing
  # about that.
  let(:calls) { [] }
  let(:chunker) { -> { calls << :chunked and [hunk] } }

  # Constructing over this is how a scenario says "and nothing chunked it".
  let(:exploding) { -> { raise "chunked when it should not have been" } }

  def lazy(old_path: "a.rb", new_path: "a.rb", chunker: self.chunker, binary: false, rendered_lines: 4)
    described_class.new(old_path:, new_path:, chunker:, binary:, rendered_lines:)
  end

  # `MarkedChangeset.of` keys its row table by the file OBJECT and `walk`
  # resolves through a no-default `rows.fetch(file)`. Two groups below exercise
  # the real thing rather than the abstract claim -- equality, and the whole row
  # graph's shareability, which `session_spec.rb`'s "the values this card adds
  # are shareable" pins for a diff. Every String is interned, or the graph would
  # be unshareable because of the FIXTURE rather than because of the file.
  def marked_over(keyed, walked = keyed)
    partition = Lain::Review::Partition.new(label: -"s", files: [walked].freeze)
    changeset = instance_double(Lain::Review::Changeset, files: [keyed], hunks: [hunk],
                                                         partitions: [partition],
                                                         base_ref: -("b" * 40), head_ref: -("h" * 40))
    marks = instance_double(Lain::Review::Marks, states: { "a.rb" => :reviewed })
    Lain::Review::Session::MarkedChangeset.of(changeset, marks)
  end

  describe "the changed-file duck" do
    it "answers its paths, status and binary-ness without chunking" do
      file = lazy(old_path: "old.rb", new_path: "new.rb", chunker: exploding)

      expect([file.old_path, file.new_path, file.path]).to eq(["old.rb", "new.rb", "new.rb"])
      expect(file.status).to eq(:renamed)
      expect(file.binary?).to be(false)
    end

    it "reports itself binary when it was built that way, still without chunking" do
      expect(lazy(chunker: exploding, binary: true).binary?).to be(true)
    end

    # {Source::ChangedFile} owns the status rule; this drives both over the
    # same path pairs so a drift is red rather than latent. The literal answers
    # are asserted too -- two objects agreeing on a raise would otherwise pass.
    it "answers exactly what a ChangedFile answers, for every path pair" do
      pairs = [["a.rb", "a.rb"], [nil, "a.rb"], ["a.rb", nil], ["a.rb", "b.rb"]]

      from_lazy = pairs.map { |old, new| lazy(old_path: old, new_path: new, chunker: exploding).status }
      from_eager = pairs.map { |old, new| changed_file(old_path: old, new_path: new, hunks: []).status }

      expect(from_lazy).to eq(from_eager)
      expect(from_lazy).to eq(%i[modified added deleted renamed])
    end

    it "interns its paths, as a ChangedFile does" do
      file = lazy(old_path: +"a.rb", new_path: +"a.rb", chunker: exploding)

      expect(file.old_path).to be_frozen
      expect(file.new_path).to be_frozen
    end
  end

  describe "chunking on demand" do
    it "chunks nothing when it is constructed" do
      expect { lazy(chunker: exploding) }.not_to raise_error
    end

    it "chunks nothing to answer the diff's own facts" do
      file = lazy

      [file.old_path, file.new_path, file.path, file.status, file.binary?]

      expect(calls).to be_empty
    end

    # The whole of what makes {Review::Bounds} able to bound a survey: a bound
    # measures a view in rendered lines, and a file that answered that by
    # chunking would chunk the corpus to decide whether to present it. The size
    # is SUPPLIED -- a corpus harvests it in the same streamed read its identity
    # pass already makes -- so this is a stored fact, not a derived one.
    it "answers what a bound measures it by, without chunking" do
      file = lazy(chunker: exploding, rendered_lines: 42)

      expect(file.rendered_lines).to eq(42)
      expect(calls).to be_empty
    end

    # The other half of "asserted, not derived", and the half a first cut left
    # out. A size nobody can check is a size a source can get wrong, and a wrong
    # one is not caught downstream: {Bounds} sums what it is told, so ONE file
    # reporting a negative cancels its neighbours and carries a 250,000-line
    # view under a 30,000-line ceiling -- the success-that-isn't-one that object
    # exists to refuse, produced by the object itself. There is no honest
    # negative; zero is honest, and is what a hunkless file answers.
    describe "the size it is told, which nothing downstream can check" do
      it "refuses a negative, which would carry the whole view under the ceiling with it" do
        expect { lazy(chunker: exploding, rendered_lines: -1) }
          .to raise_error(ArgumentError, /-1/)
      end

      it "refuses a negative however it is spelled, since the coercion runs first" do
        expect { lazy(chunker: exploding, rendered_lines: -400_000) }.to raise_error(ArgumentError)
      end

      it "accepts zero, which is what a file with nothing to render honestly costs" do
        expect(lazy(chunker: exploding, rendered_lines: 0).rendered_lines).to eq(0)
      end

      # Coerced for {Bounds}' own reason: a ceiling compared against a String is
      # a `nil`-shaped failure with an `ArgumentError`'s cure. A decimal String
      # is deliberately NOT blessed -- `Integer("010")` is 8, and a line count
      # that reads as octal is a defect nobody would look for.
      it "refuses what is not a number at all, rather than coercing it to zero" do
        expect { lazy(chunker: exploding, rendered_lines: "many") }.to raise_error(ArgumentError)
        expect { lazy(chunker: exploding, rendered_lines: nil) }.to raise_error(TypeError)
      end

      # The port's own law, held against the one file type that could break it:
      # every source running it in `review_source.rb` derives its sizes off
      # parsed hunks, so the law never met a witness with anything to get wrong.
      it_behaves_like "files a bound can size" do
        let(:sized_files) { [lazy(chunker: exploding, rendered_lines: 0), lazy(rendered_lines: 7)] }
      end
    end

    it "runs the chunker once however often the hunks are read" do
      file = lazy

      3.times { file.hunks }

      expect(calls.size).to eq(1)
    end

    it "answers the very same frozen array every time, as a ChangedFile does" do
      file = lazy

      expect(file.hunks).to eq([hunk])
      expect(file.hunks).to be_frozen
      expect(file.hunks).to equal(file.hunks)
    end

    # A hunkless file is a real shape ({MarkedChangeset::HUNKLESS}), so the
    # empty case gets the same once-only claim as any other. Named for what it
    # checks: `||=` on the box would ALSO be correct here, because `[]` is
    # truthy, so this does not distinguish the box from `||=` and must not
    # claim to.
    it "runs the chunker once for a file that chunks to nothing, too" do
      file = lazy(chunker: -> { calls << :chunked and [] })

      2.times { expect(file.hunks).to eq([]) }

      expect(calls.size).to eq(1)
    end

    # The array belongs to the CHUNKER, which is injected and unknown -- freezing
    # it in place would raise inside somebody else's object on a LATER file, with
    # nothing in the backtrace naming the file that froze it. `ChangedFile` gets
    # away with `hunks.freeze` because its only caller is `Parser`, minting a
    # fresh array per file.
    it "never freezes the array the chunker handed over, which it does not own" do
      produced = [hunk]
      file = lazy(chunker: -> { produced })

      expect(file.hunks).to eq([hunk])
      expect(file.hunks).to be_frozen
      expect(produced).not_to be_frozen
    end

    # `dup` copies the ivars and does NOT re-freeze, so an unfrozen copy would
    # otherwise write its chunking into the frozen original's cache -- mutating a
    # frozen object's state through an alias.
    it "gives a dup and a clone their own empty memo, and freezes both" do
      original = lazy
      copy = original.dup

      copy.hunks

      expect(copy).to be_frozen
      expect(original.clone).to be_frozen
      expect(calls.size).to eq(1)
      original.hunks
      expect(calls.size).to eq(2)
    end
  end

  describe "Ractor shareability, which this trades away and says so" do
    it "is frozen but NOT deeply frozen, unlike the ChangedFile it stands in for" do
      file = lazy

      expect(file).to be_frozen
      expect(file).not_to be_deeply_frozen
      expect(changed_file).to be_deeply_frozen
    end

    it "is unshareable before anything has chunked it, so the memo is not the only reason" do
      expect(Ractor.shareable?(lazy(chunker: exploding))).to be(false)
    end

    # The second pin, and the one no other card owns. `session_spec.rb`'s "the
    # values this card adds are shareable" asserts `Ractor.shareable?` of the
    # WHOLE marked-changeset graph, whose `FileRow`s hold the file. A lazy leaf
    # propagates straight up, so that pin is a DIFF-source law too -- stated
    # here, where B8's author will find it, rather than discovered by a red run.
    it "makes the whole marked-changeset graph unshareable, where an eager file leaves it shareable" do
      expect(Ractor.shareable?(marked_over(changed_file))).to be(true)
      expect(Ractor.shareable?(marked_over(lazy))).to be(false)
    end
  end

  describe "equality, against the row table's own fetch" do
    let(:file) { lazy }
    let(:twin) { lazy }

    it "is value equality: a re-derived file is eql? and hashes the same" do
      expect(file).to eq(twin)
      expect(file).to eql(twin)
      expect(file.hash).to eq(twin.hash)
      expect(file).not_to equal(twin)
    end

    it "lets a re-derived file fetch the row its twin keyed" do
      marked = marked_over(file, twin)

      expect(marked.partitions.first.files.first).to equal(marked.files.first)
    end

    it "keeps that fetch resolving after one of them has chunked, so the memo is not in the key" do
      file.hunks
      marked = marked_over(file, twin)

      expect(file.hash).to eq(twin.hash)
      expect(marked.partitions.first.files.first).to equal(marked.files.first)
    end

    # The negative half, so the example above is not passing on a fetch that
    # would resolve anything at all -- and the message must NAME the file that
    # missed, because this is the failure the class doc calls the principal one.
    it "is a KeyError at the walk when the file is a different path, and it names that path" do
      expect { marked_over(file, lazy(old_path: "z.rb", new_path: "z.rb")) }
        .to raise_error(KeyError, /z\.rb/)
    end

    # The size is DERIVED from the same content the chunker stands for, so it
    # adds nothing to the value and two sources disagreeing about it is a bug in
    # one of them rather than two different files. Keeping it out is also what
    # stops that bug surfacing as a `KeyError` from a row table three objects
    # away, which names the path and could not name the size.
    it "is equal to a file over the same path and chunker that reports another size" do
      expect(file).to eq(lazy(rendered_lines: file.rendered_lines + 1))
      expect(file.hash).to eq(lazy(rendered_lines: file.rendered_lines + 1).hash)
    end

    # The chunker is part of the value: two files over one path that would
    # produce different hunks are different files.
    it "is not equal to a file over the same path with another chunker" do
      other = lazy(chunker: -> { [hunk] })

      expect(file).not_to eq(other)
      expect { marked_over(file, other) }.to raise_error(KeyError)
    end

    # The escape from the constraint above, and the cheaper one: equality
    # delegates to the chunker's own, so a chunker shaped as a VALUE compares
    # equal across derivations where a rebuilt lambda never can.
    it "compares equal across derivations when the chunker is itself a value" do
      valued = Data.define(:hunks) { def call = hunks }
      marked = marked_over(lazy(chunker: valued.new(hunks: [hunk].freeze)),
                           lazy(chunker: valued.new(hunks: [hunk].freeze)))

      expect(marked.partitions.first.files.first).to equal(marked.files.first)
    end

    # `instance_of?`, not `is_a?`: under `is_a?` the base would equal a subclass
    # instance while the subclass did not equal it back.
    it "is not equal to a subclass instance, in either direction" do
      sub = Class.new(described_class).new(old_path: "a.rb", new_path: "a.rb", chunker:, rendered_lines: 4)

      expect(file == sub).to be(false)
      expect(sub == file).to be(false)
    end

    # `Data#hash` includes the class, and this class cites `Data` as its model.
    # Without it a subclass shares the bucket while comparing unequal, and so
    # does a bare Array of the same parts.
    it "hashes its class in, so an unequal object does not share its bucket" do
      sub = Class.new(described_class).new(old_path: "a.rb", new_path: "a.rb", chunker:, rendered_lines: 4)

      expect(sub.hash).not_to eq(file.hash)
      expect(file.hash).not_to eq([file.old_path, file.new_path, file.binary, file.chunker].hash)
    end
  end

  # Ruby truncates a key's `inspect` at 80 characters in a KeyError message and
  # the default one spends most of that on an object id and the memo, so the
  # path and status -- the two facts that identify the file that missed -- are
  # what gets cut.
  describe "inspect, which is what a KeyError prints" do
    it "names the path and the status, and nothing else, however much has been chunked" do
      file = lazy
      file.hunks

      expect(file.inspect).to eq('#<Lain::Review::LazyFile "a.rb" modified>')
      expect(lazy(old_path: nil, new_path: "new.rb", chunker: exploding).inspect)
        .to eq('#<Lain::Review::LazyFile "new.rb" added>')
    end
  end
end
