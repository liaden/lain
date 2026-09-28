# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Driven against a real directory throughout, because the directory IS the
# subject: {Lain::Store} is a Hash that dies with the process, and the whole
# reason this one exists is that an attachment's bytes must outlive the turn
# that made them while only its digest rides the Timeline.
RSpec.describe Lain::Attachment::Store, :seam do
  subject(:store) { described_class.for(root: project, paths: paths_at(state)) }

  around do |example|
    Dir.mktmpdir("lain-attachment-store") do |dir|
      @dir = dir
      @state = File.join(dir, "state")
      @project = File.join(dir, "project")
      FileUtils.mkdir_p(@project)
      example.run
    end
  end

  attr_reader :dir, :state, :project

  def paths_at(home) = Lain::Paths.new(env: { "XDG_STATE_HOME" => home, "HOME" => home })

  # `count` threads onto one store with the same bytes, each answering its
  # digest or the exception that stopped it -- a raise inside a thread is
  # otherwise re-raised at `#value` and would end the example before the others
  # are heard from.
  def racing(count)
    Array.new(count) { Thread.new { put_or_error } }.map(&:value)
  end

  def put_or_error
    store.put(bytes)
  rescue StandardError => e
    e
  end

  # A PNG header, a NUL, a high byte and a lone 0x80 continuation byte: nothing
  # that survives a round trip through a String that got re-tagged UTF-8.
  let(:bytes) { (+"\x89PNG\r\n\x1a\n\x00\xff\x80binary").force_encoding(Encoding::BINARY) }

  it "fetches back by digest the bytes it was given" do
    expect(store.fetch(store.put(bytes))).to eq(bytes)
  end

  # Content addressing's whole claim: storing the same bytes twice names them
  # once, so a screenshot taken twice costs one file.
  it "stores identical bytes once, under one digest" do
    expect(store.put(bytes)).to eq(store.put(bytes.dup))
  end

  # Subagents are THREADS in one process over one store, which is this class's
  # setting rather than an exotic case, and two of them attaching the same
  # screenshot is the idempotent case above. A scratch path shared by every
  # writer makes the first rename move the inode out from under the rest.
  it "lets many threads in one process store the same bytes, each getting the digest" do
    outcomes = racing(6)

    expect(outcomes.grep(StandardError)).to be_empty
    expect(outcomes.uniq.size).to eq(1)
    expect(store.fetch(outcomes.first)).to eq(bytes)
  end

  # A scratch file is not a blob and a reader must never mistake one for one --
  # which it cannot, since `key?` looks only for the digest's own name. What it
  # would be is unreferenced garbage in a store nothing prunes, so a burst that
  # completed leaves none behind.
  it "leaves no scratch file behind once its writers are done" do
    racing(6)

    expect(Dir.glob(File.join(store.root, "**", "*.partial"))).to be_empty
  end

  # A store relocating after construction because somebody else still held the
  # String is the shape a frozen object is supposed to make impossible.
  it "holds a root of its own, which a caller mutating the string it passed cannot move" do
    handed = +File.join(dir, "movable")
    elsewhere = described_class.new(root: handed)
    handed << "-hijacked"

    expect(elsewhere.root).to eq(File.join(dir, "movable"))
    expect(elsewhere).to be_deeply_frozen
  end

  # A lenient path and a strict comparison disagreeing is how INTACT bytes come
  # to raise the integrity alarm, and this is the shape the consumers produce: a
  # tool hands the digest to the model, the model echoes it back in an image
  # block, and a prefix or a letter's case does not survive the round trip.
  describe "the spellings of a digest" do
    it "agrees between key? and fetch on every spelling it accepts" do
      digest = store.put(bytes)
      spellings = [digest, "blake3:#{digest.delete_prefix("blake3:").upcase}"]

      expect(spellings.select { |spelling| store.key?(spelling) }).to eq(spellings)
      expect(spellings.map { |spelling| store.fetch(spelling) }).to eq([bytes, bytes])
    end

    it "refuses an unprefixed digest from BOTH doors, rather than one answering and the other alarming" do
      hex = store.put(bytes).delete_prefix("blake3:")

      expect { store.key?(hex) }.to raise_error(ArgumentError, /#{hex}/)
      expect { store.fetch(hex) }.to raise_error(ArgumentError, /#{hex}/)
    end
  end

  # The criterion the in-memory Store cannot meet. The child does the writing
  # AFTER the fork, so the parent's memory never held those bytes -- the only
  # way they reach the assertion is off disk, through a store object built
  # fresh in the reading process.
  it "hands back byte-identical bytes a second process wrote" do
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(described_class.for(root: project, paths: paths_at(state)).put(bytes))
      exit!(0)
    end
    writer.close
    digest = reader.read.tap { reader.close }
    Process.waitpid(pid)

    fetched = described_class.for(root: project, paths: paths_at(state)).fetch(digest)

    expect(fetched.bytes).to eq(bytes.bytes)
    expect(fetched.encoding).to eq(Encoding::BINARY)
  end

  # Two projects, two directories: a digest one project holds is not one the
  # other can answer, which is what keys the container by the project.
  it "addresses a directory per project" do
    other = File.join(dir, "elsewhere-project")
    FileUtils.mkdir_p(other)
    digest = store.put(bytes)

    elsewhere = described_class.for(root: other, paths: paths_at(state))

    expect(elsewhere.root).not_to eq(store.root)
    expect { elsewhere.fetch(digest) }.to raise_error(described_class::Missing)
  end

  describe "a digest no store holds" do
    # Answering nil would put the decision in a caller that has no way to make
    # it: an image block resolved to nothing is a question about a picture the
    # model never saw.
    it "refuses loudly, naming the digest and the store" do
      absent = "blake3:#{"0" * 64}"

      expect { store.fetch(absent) }.to raise_error(described_class::Missing, /#{absent}/)
      expect { store.fetch(absent) }.to raise_error(described_class::Missing, /#{Regexp.escape(store.root)}/)
    end

    it "answers false rather than raising when merely asked" do
      expect(store).not_to be_key("blake3:#{"0" * 64}")
    end

    # A digest that is not one is a caller bug, not a miss -- it could never
    # have been stored, so reporting it as absent would hide a typo.
    it "refuses a string that is not a digest at all" do
      expect { store.fetch("not-a-digest") }.to raise_error(ArgumentError, /not-a-digest/)
    end
  end

  # The address is a claim about the bytes, so a file whose bytes stopped
  # matching its name is not a miss either.
  it "refuses bytes on disk that no longer hash to their own name" do
    digest = store.put(bytes)
    File.binwrite(Dir.glob(File.join(store.root, "**", "*")).find { |path| File.file?(path) }, "tampered")

    expect { store.fetch(digest) }.to raise_error(described_class::Corrupt, /#{digest}/)
  end

  # `sensitivity/regions.rb` says why in full: two keyspaces sharing a tag are
  # one keyspace, and nothing would ever say so out loud.
  it "cannot collide with a workspace snapshot blob over the same bytes" do
    expect(store.put(bytes)).not_to eq(Lain::Workspace::Snapshot::Blob.new(bytes:).digest)
  end

  # The construction site the rest of the chunk hangs off: one store per run,
  # built where the toolset is, so the middleware that resolves a reference on
  # the way to the wire and the tool that puts the bytes there cannot end up
  # addressing two directories. Both consumers are still to be written, so what
  # is provable today is that there is exactly one object to hand them.
  describe "the run's one store, from the real toolset construction path" do
    let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }, root: Dir.pwd) }
    let(:chronicle) { Lain::CLI::Chronicle::Null.new }
    let(:recorder) { Lain::Memory::Recorder.new }
    let(:ask_human) { Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.new }) }

    def toolset_build(root:)
      Lain::CLI::Wiring::ToolsetBuild.new(
        backend:, provider: backend.provider(spool: chronicle.spool), chronicle:, options: {},
        supervisor: Lain::Supervisor.new(journal: RecordingChannel.new), parent: -> { Lain::Timeline.new },
        journal: RecordingChannel.new, library: backend.library, epic: Lain::CLI::EpicMount::NoEpic, root:,
        switchboard: -> { SpecNulls::NoSwitchboard }, askers: SpecNulls::UnwiredAskers.build
      )
    end

    it "exposes one store, the same object however often it is asked, and after the toolset is built" do
      build = toolset_build(root: project)
      first = build.attachments
      build.build(recorder, ask_human:)

      expect(build.attachments).to be(first)
    end

    it "addresses the project's own durable container, outside the project tree" do
      expect(toolset_build(root: project).attachments.root)
        .to eq(Lain::ProjectDir.new(root: project).container(described_class::KIND))
    end
  end
end
