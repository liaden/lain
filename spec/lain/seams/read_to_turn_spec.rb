# frozen_string_literal: true

require "tmpdir"

# The seam F62 shipped through. `read_file` was specced by itself, the Timeline
# was specced by itself, and the raise lives in neither: `Canonical.normalize`
# inside {Lain::Event::Payload} on {Lain::Timeline#commit}. The nearest existing
# example -- the `unreadable` one in `redact_secret_reads_spec.rb` -- INJECTS
# content and never runs the real reader, so no bytes a real `File.read`
# produced ever crossed into a commit.
#
# So: a real file of random bytes, a real {Lain::Tools::ReadFile}, a real
# {Lain::Agent::ToolRunner}, a real {Lain::Timeline}, and no double anywhere
# between them. The channel and the middleware stack are each object's own
# default (Null, empty) rather than a stand-in, and the secret boundary is
# deliberately absent: it is a witness to this defect, not a participant.
RSpec.describe "a tier-1 read reaching the Timeline", :seam do
  let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new]) }
  let(:handler) { Lain::Effect::Handler::Live.new(toolset:) }
  let(:runner) { Lain::Agent::ToolRunner.new(handler:, toolset:) }
  let(:session) { Lain::Session.new }
  let(:path) { binary_file }

  around do |example|
    Dir.mktmpdir("lain-read-to-turn") do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  # Random bytes, with byte 0 pinned to `\xFF` -- which is not legal UTF-8 in
  # any position. Randomness is what the scenario asks for; the pin is what
  # makes invalidity STRUCTURAL rather than an artifact of what the seed
  # happened to produce, so the file cannot quietly become readable if the RNG
  # ever changes.
  def binary_file(name = "noise.bin")
    File.join(dir, name).tap do |file|
      File.binwrite(file, "\xFF".b + Random.new(62).bytes(4096))
    end
  end

  def read_call(file, **window)
    tool_response(["tu_read", "read_file", { "path" => file }.merge(window.transform_keys(&:to_s))])
  end

  # The production path, start to finish: dispatch the turn's calls, then commit
  # what they answered with. {Lain::Agent::ToolDelivery#settle} is these two
  # lines and nothing else, which is why the seam is drawn here rather than
  # around the whole Agent -- no provider, no loop, no scripted second turn
  # standing between the bytes and the raise.
  def commit(response)
    Lain::Timeline.empty.commit(role: :user, **runner.delivery(response, context: session))
  end

  def result_block(timeline) = timeline.head.content.first

  # Asserted through `Canonical` itself and not through `valid_encoding?`,
  # because {Lain::Tools::ReadFile::Read#committable?} deliberately RESTATES
  # Canonical's rule instead of calling it (to avoid interning a quarter-
  # megabyte of file contents per read). Restating is what can drift, so the
  # precondition asks the authority directly.
  it "is reading bytes that Canonical itself refuses" do
    bytes = File.binread(binary_file).force_encoding(Encoding::UTF_8)

    expect { Lain::Canonical.normalize(bytes) }.to raise_error(Lain::Canonical::UnsupportedType)
  end

  describe "a whole-file read of random bytes" do
    it "commits a turn instead of raising out of Canonical" do
      expect { commit(read_call(path)) }.not_to raise_error
    end

    it "carries the refusal into the committed turn" do
      block = result_block(commit(read_call(path)))

      expect(block["is_error"]).to be(true)
      expect(block["tool_use_id"]).to eq("tu_read")
      expect(block["content"]).to eq(
        "#{path} is not valid UTF-8, so its contents cannot be recorded as part of this conversation " \
        "-- instead, identify it with bash (`file PATH`), or look at its bytes with bash (`xxd PATH | head`)"
      )
    end

    # `.b` on BOTH sides, which is the idiom `read_file_spec.rb` already uses.
    # `String#include?` with a broken-coderange needle answers false whatever
    # the haystack holds, so searching for a UTF-8-tagged `\xFF` would pass over
    # content carrying every byte of the file. The search has to be byte-wise to
    # discriminate at all.
    it "commits none of the file's bytes" do
      expect(result_block(commit(read_call(path)))["content"].b).not_to include("\xFF".b)
    end

    it "leaves the read unrecorded, because the model learned nothing about the file" do
      commit(read_call(path))

      expect(session.reads).to be_empty
    end
  end

  describe "a windowed read of the same bytes" do
    it "commits a turn instead of raising out of Canonical" do
      expect { commit(read_call(path, offset: 1, limit: 1)) }.not_to raise_error
    end

    it "refuses with the same sentence, because an offset cannot make bytes text" do
      whole = result_block(commit(read_call(path)))["content"]

      expect(result_block(commit(read_call(path, offset: 1, limit: 1)))["content"]).to eq(whole)
    end

    it "leaves the read unrecorded" do
      commit(read_call(path, offset: 1, limit: 1))

      expect(session.reads).to be_empty
    end
  end

  # The window examples above see the SAME pinned byte the whole-file read does,
  # so on their own they prove which reader ran and never which bytes were
  # judged. Here line 1 is ordinary text and the invalid bytes start on line 2,
  # which is the only shape where the two readers can legitimately disagree:
  # the window is judged on what the window actually read.
  describe "a file whose invalidity is out of the window's reach" do
    let(:path) do
      File.join(dir, "mixed.txt").tap do |file|
        File.binwrite(file, "a valid first line\n".b + "\xFF".b + Random.new(7).bytes(64) + "\n".b)
      end
    end

    it "refuses the whole read, without raising" do
      expect { commit(read_call(path)) }.not_to raise_error
      expect(result_block(commit(read_call(path)))["is_error"]).to be(true)
    end

    it "SERVES a window over the valid line, and records it as an incomplete read" do
      block = result_block(commit(read_call(path, offset: 1, limit: 1)))

      expect(block["is_error"]).to be(false)
      expect(block["content"]).to include("a valid first line")
      expect(session.reads).to eq([path])
      expect(session.read?(path)).to be(false)
    end

    it "refuses a window over the invalid line, without raising, and records nothing" do
      expect { commit(read_call(path, offset: 2, limit: 1)) }.not_to raise_error
      expect(result_block(commit(read_call(path, offset: 2, limit: 1)))["is_error"]).to be(true)
      expect(session.reads).to be_empty
    end
  end

  # The control. If this went red the seam would be proving nothing about
  # binary files -- it would be proving that nothing commits at all.
  it "still commits a real UTF-8 file's contents through the same path" do
    text = File.join(dir, "text.txt")
    File.write(text, "héllo from disk\n")

    block = result_block(commit(read_call(text)))

    expect(block["is_error"]).to be(false)
    expect(block["content"]).to include("héllo from disk")
    expect(session.reads).to eq([text])
  end
end
