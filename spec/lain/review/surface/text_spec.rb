# frozen_string_literal: true

require "stringio"

# Lain::Review::Changeset (T7) and Lain::Review::Marks (T8) are siblings that
# have not landed -- see Surface's own port doc ("What present's changeset
# argument answers") for the exact duck assumed here: `#files` (Enumerable of
# `#path`/`#state`) for the flat view, `#partitions` (Enumerable of
# `#label`/`#files`) for the grouped one. Everything below builds that
# shape directly with anonymous Structs rather than a real Changeset/Marks,
# matching `spec/lain/session_pins_spec.rb` and `spec/lain/status_feed_spec.rb`'s
# own house style for a duck double.
RSpec.describe Lain::Review::Surface::Text do
  subject(:surface) { described_class.new(sink:) }

  let(:sink) { StringIO.new }

  def file_entry(path:, state:) = Struct.new(:path, :state).new(path, state)

  def commit_entry(subject:, files:) = Struct.new(:label, :files).new(subject, files)

  def changeset(files:, commits: []) = Struct.new(:files, :partitions).new(files, commits)

  def real_anchor(path: "lib/lain/agent.rb", line: 14)
    Lain::Review::Anchor.new(path:, side: :new, line:, anchor_text: "  @store.write(input)", revision: "abc123")
  end

  # One file per tri-state, split across two commits so :commits and
  # :cumulative scope can be told apart by more than row count.
  def reviewed = file_entry(path: "lib/a.rb", state: :reviewed)
  def partial = file_entry(path: "lib/b.rb", state: :partial)
  def unreviewed = file_entry(path: "lib/c.rb", state: :unreviewed)

  def two_commit_changeset
    changeset(files: [reviewed, partial, unreviewed],
              commits: [commit_entry(subject: "add a.rb", files: [reviewed]),
                        commit_entry(subject: "touch b.rb and c.rb", files: [partial, unreviewed])])
  end

  # REAL {Review::Partition}s over the same file entries -- the grouped
  # rendering is drawn from whatever the session partitioned by, and a Struct
  # could answer a `#label` no strategy ever produces.
  def directory_changeset
    spec_file = file_entry(path: "spec/c.rb", state: :unreviewed)
    changeset(files: [reviewed, partial, spec_file],
              commits: [Lain::Review::Partition.new(label: "lib", files: [reviewed, partial]),
                        Lain::Review::Partition.new(label: "spec", files: [spec_file])])
  end

  it_behaves_like "a review surface",
                  changeset: -> { two_commit_changeset },
                  anchor: -> { real_anchor },
                  transcript: -> { sink.string }

  it "passes Surface.check! -- the whole port, publicly, with the right shapes" do
    expect { Lain::Review::Surface.check!(surface) }.not_to raise_error
  end

  describe "#present" do
    it "writes the rendering into the injected sink, never $stdout" do
      surface.present(two_commit_changeset, scope: :cumulative)

      expect(sink.string).not_to be_empty
    end

    it "renders the tri-state with three distinct markers" do
      surface.present(two_commit_changeset, scope: :cumulative)

      expect(sink.string).to include("[x] lib/a.rb")
      expect(sink.string).to include("[~] lib/b.rb")
      expect(sink.string).to include("[ ] lib/c.rb")
    end

    it "heads each group with its partition's label at :commits scope" do
      surface.present(two_commit_changeset, scope: :commits)

      expect(sink.string).to include("add a.rb")
      expect(sink.string).to include("touch b.rb and c.rb")
    end

    # The axis reaching the renderer, against a REAL {Review::Partition} rather
    # than a Struct: a directory label heads the files under it, and the same
    # renderer that draws the commit walk draws it.
    it "heads each group with its directory at :by_directory scope" do
      surface.present(directory_changeset, scope: :by_directory)

      expect(sink.string).to eq(<<~TABLE)
        lib
          [x] lib/a.rb
          [~] lib/b.rb

        spec
          [ ] spec/c.rb
      TABLE
    end

    # The positive assertion is what makes this catch a silent-sink mutant --
    # a `#present` that writes nothing would pass the two `not_to include`s
    # for free (a review-panel finding on this exact example: pure negative
    # space survives a no-op).
    it "renders one flat table with no partition labels at :cumulative scope" do
      surface.present(two_commit_changeset, scope: :cumulative)

      expect(sink.string).to include("[x] lib/a.rb")
      expect(sink.string).not_to include("add a.rb")
      expect(sink.string).not_to include("touch b.rb and c.rb")
    end

    it "raises on a state outside the closed tri-state, rather than a blank marker" do
      broken = changeset(files: [file_entry(path: "x.rb", state: :bogus)])

      expect { surface.present(broken, scope: :cumulative) }.to raise_error(KeyError)
    end

    # BLOCKER fix: STATE_MARKERS used to be keyed by Symbol alone, so the
    # canonical String spelling every journaled record actually stores
    # (Review::FILE_STATES) raised KeyError. Both spellings must work.
    it "accepts the canonical String state, not only the Symbol" do
      cs = changeset(files: [file_entry(path: "a.rb", state: "reviewed"),
                             file_entry(path: "b.rb", state: "partial"),
                             file_entry(path: "c.rb", state: "unreviewed")])

      surface.present(cs, scope: :cumulative)

      expect(sink.string).to include("[x] a.rb")
      expect(sink.string).to include("[~] b.rb")
      expect(sink.string).to include("[ ] c.rb")
    end

    it "raises loudly on an unknown scope, rather than silently rendering the flat table" do
      expect { surface.present(two_commit_changeset, scope: :cumulatve) }.to raise_error(KeyError)
    end

    # Aaron's fix: git yields bytes, and a changeset can legitimately mix a
    # clean UTF-8 path with one carrying invalid bytes. Before the fix this
    # raised Encoding::CompatibilityError inside #join, naming neither path.
    #
    # UTF-8 + #scrub, not BINARY (the fix's own second round): #scrub
    # replaces exactly the two invalid bytes with "?" apiece, leaving the
    # clean UTF-8 path untouched -- degrade the unreadable half, not the
    # legible one, and the RESULT stays validly UTF-8-encoded (checked below,
    # since that is exactly what a real Sink::IOAdapter + Canonical.dump
    # needs and BINARY did not give it).
    it "does not raise on a mixed UTF-8/invalid-byte changeset, and scrubs only the invalid bytes" do
      utf8_path = "lib/café.rb"
      binary_path = (+"lib/\xFF\xFEbroken.rb").force_encoding(Encoding::BINARY)
      cs = changeset(files: [file_entry(path: utf8_path, state: :reviewed),
                             file_entry(path: binary_path, state: :unreviewed)])

      expect { surface.present(cs, scope: :cumulative) }.not_to raise_error
      expect(sink.string).to include("[x] lib/café.rb")
      expect(sink.string).to include("[ ] lib/??broken.rb")
      expect(sink.string.encoding).to eq(Encoding::UTF_8)
      expect(sink.string.valid_encoding?).to be(true)
    end

    it "names emptiness explicitly rather than writing a bare newline" do
      surface.present(changeset(files: []), scope: :cumulative)

      expect(sink.string).to eq("(nothing changed)\n")
    end

    # A UTF-8 path over a REAL Sink::IOAdapter + Channel, not the StringIO
    # every other example uses: the round-trip this pins is exactly the one
    # the encoding fix's second round exists for. `Encoding::BINARY` (the
    # first cut) passed every example above -- StringIO does not care what
    # it is handed -- and STILL regressed a plain, all-ASCII, non-suspect
    # path the moment it reached a real Channel: String#<< onto Sink's fresh
    # `+""` buffer adopts the OTHER operand's encoding when the buffer is
    # still empty, so the emitted ToolOutput#bytes came out ASCII-8BIT-tagged
    # even though nothing in it was ever actually binary.
    it "round-trips a UTF-8 path through a real Sink::IOAdapter, Canonical.dump, and JSON.generate, without warning" do
      channel = RecordingChannel.new
      adapter = Lain::Sink::IOAdapter.new(channel, tool_use_id: "toolu_1", stream: :stdout)
      real_surface = described_class.new(sink: adapter)

      real_surface.present(changeset(files: [file_entry(path: "café.rb", state: :reviewed)]), scope: :cumulative)
      bytes = channel.events.first.bytes

      expect(bytes.encoding).to eq(Encoding::UTF_8)
      expect { Lain::Canonical.dump(bytes) }.not_to raise_error

      warned = nil
      Warning.define_singleton_method(:warn) { |message| warned = message }
      begin
        JSON.generate(bytes)
      ensure
        Warning.singleton_class.send(:remove_method, :warn)
      end
      expect(warned).to be_nil
    end
  end

  describe "STATE_MARKERS" do
    # NOT `STATE_MARKERS.keys.sort == Review::FILE_STATES.sort` -- a
    # review-panel finding: `STATE_MARKERS` is built as
    # `FILE_STATES.to_h { ... }`, so its keys ARE `FILE_STATES` by
    # construction, for ANY glyph mapping whatsoever. That reads as the
    # vocabulary pin and proves nothing. What the derivation actually buys is
    # that a state with no glyph decided raises rather than rendering blank
    # -- asserted here directly, against the private lookup, since
    # `Review::FILE_STATES` is a closed three-member set and cannot itself be
    # made to carry an unhandled fourth member without editing this file too.
    it "raises for a state with no glyph decided, rather than rendering one blank" do
      expect { described_class.send(:glyph_for, "bogus") }.to raise_error(/no glyph declared for file state "bogus"/)
    end
  end

  # The completeness law that replaced a literal equality against
  # a two-member scope vocabulary: what has to hold is that every strategy anybody can be
  # handed HAS a rendering here, which an equality against a two-member
  # vocabulary stopped saying the moment a third strategy shipped.
  describe "SCOPE_RENDERER" do
    it "declares a rendering for every registered partition strategy" do
      expect(described_class::SCOPE_RENDERER.keys)
        .to include(*Lain::Review::Partition::STRATEGIES.keys)
    end

    it "resolves a real private renderer for each, so a name alone is not enough" do
      expect(described_class::SCOPE_RENDERER.values)
        .to all(satisfy { |renderer| described_class.private_method_defined?(renderer) })
    end

    it "refuses a strategy it declares no rendering for, naming it" do
      expect { surface.present(two_commit_changeset, scope: :by_size) }
        .to raise_error(KeyError, /by_size/)
    end
  end

  describe "#annotate" do
    it "writes an observable line naming the anchor, kind and text" do
      anchor = real_anchor
      surface.annotate(anchor, "needs a test", kind: :question)

      expect(sink.string).to include("needs a test")
      expect(sink.string).to include("question")
      expect(sink.string).to include("#{anchor.path}:#{anchor.line}")
    end
  end

  describe "#mark" do
    it "writes an observable acknowledgement of the hunk and state" do
      surface.mark("hunk-content-v1:deadbeef", :reviewed)

      expect(sink.string).to include("hunk-content-v1:deadbeef")
      expect(sink.string).to include("reviewed")
    end
  end

  describe "#thread" do
    it "announces the position, carrying no prior conversation of its own" do
      anchor = real_anchor
      surface.thread(anchor)

      expect(sink.string).to include("#{anchor.path}:#{anchor.line}")
    end

    # NIT fix: the fallback used to be a raw #inspect, which prints
    # `#<Object:0x...>` -- a memory address that names nothing a transcript's
    # reader can act on. It now mirrors Surface.candidate_name's own idiom.
    it "names the class rather than a raw #inspect when the anchor is a generic double" do
      surface.thread(Object.new)

      expect(sink.string).to include("Object")
      expect(sink.string).not_to match(/#<.*0x/)
    end
  end

  describe "#verdict" do
    it "returns nil -- a batch surface has nobody to ask synchronously" do
      expect(surface.verdict).to be_nil
    end
  end

  describe "#refuse" do
    it "writes the refusal's reason into the sink" do
      surface.refuse("not today")

      expect(sink.string).to include("refused")
      expect(sink.string).to include("not today")
    end
  end
end
