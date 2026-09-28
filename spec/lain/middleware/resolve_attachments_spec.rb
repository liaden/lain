# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# Driven against a real {Lain::Attachment::Store} on a real directory, with a
# real {Lain::Agent::ModelCaller} and a real {Lain::Middleware::JournalRequests}
# either side of the subject: what this middleware exists to make true is a
# relationship between two byte streams -- what the journal records and what the
# provider receives -- and neither is observable through a double.
RSpec.describe Lain::Middleware::ResolveAttachments, :seam do
  around do |example|
    Dir.mktmpdir("lain-resolve-attachments") do |dir|
      @state = File.join(dir, "state")
      @project = File.join(dir, "project")
      FileUtils.mkdir_p(@project)
      example.run
    end
  end

  attr_reader :state, :project

  let(:store) do
    Lain::Attachment::Store.for(root: project,
                                paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => state, "HOME" => state }))
  end

  # A PNG signature, a NUL, a high byte and a lone continuation byte: bytes that
  # do not survive being read as text, so an example that passes has really
  # carried them through base64 rather than through a String.
  let(:png) { (+"\x89PNG\r\n\x1a\n\x00\xff\x80pixels").force_encoding(Encoding::BINARY) }
  let(:digest) { store.put(png) }
  let(:reference) { Lain::Attachment::Reference.new(digest:, media_type: "image/png") }
  let(:base64) { [png].pack("m0") }

  let(:mock) do
    Lain::Provider::Mock.new(responses: [Lain::Response.new(content: [{ "type" => "text", "text" => "a cat" }],
                                                            stop_reason: :end_turn)])
  end

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def asking(content)
    Lain::Request.new(model: "qwen3:4b", max_tokens: 64,
                      messages: [{ "role" => "user", "content" => content }])
  end

  def dispatch(request, middleware)
    Lain::Agent::ModelCaller.new(provider: mock, middleware: Lain::Middleware::Stack.new(middleware)).call(request)
  end

  def journaled(type)
    journal_io.string.each_line.map { |line| JSON.parse(line) }.select { |record| record["type"] == type }
  end

  def sent_image(request) = request.messages.dig(0, "content", 1)

  describe "what the journal keeps against what the wire carries" do
    it "records the address and sends the bytes, from one dispatch" do
      dispatch(asking([{ "type" => "text", "text" => "what is on it" }, reference.block]),
               [Lain::Middleware::JournalRequests.new(journal:), described_class.new(attachments: store)])

      expect(journaled("request_sent").first["payload"]["messages"].dig(0, "content", 1, "source"))
        .to include("type" => "attachment", "digest" => digest, "media_type" => "image/png")
      expect(journal_io.string).not_to include(base64)
      expect(sent_image(mock.last_request)["source"]).to include("type" => "base64", "media_type" => "image/png")
      expect(sent_image(mock.last_request)["source"]["data"].unpack1("m0")).to eq(png)
    end

    # --no-journal is not a mode this middleware has: the record is what the
    # address buys, and the bytes are what the model needs, and only one of the
    # two depends on anybody recording anything.
    it "sends the bytes with no journalling middleware in the stack at all" do
      dispatch(asking([reference.block]), [described_class.new(attachments: store)])

      expect(mock.last_request.messages.dig(0, "content", 0, "source")["data"].unpack1("m0")).to eq(png)
      expect(journal_io.string).to be_empty
    end
  end

  describe "where an address can hide" do
    it "resolves one nested inside a tool_result's own content" do
      result = { "type" => "tool_result", "tool_use_id" => "call_1",
                 "content" => [{ "type" => "text", "text" => "the page" }, reference.block] }

      dispatch(asking([result]), [described_class.new(attachments: store)])

      nested = mock.last_request.messages.dig(0, "content", 0, "content", 1)
      expect(nested["source"]["data"].unpack1("m0")).to eq(png)
    end

    it "leaves a request carrying no address alone, by identity" do
      request = asking([{ "type" => "text", "text" => "no pictures here" }])

      dispatch(request, [described_class.new(attachments: store)])

      expect(mock.last_request).to be(request)
    end
  end

  # The address is what rides the Timeline, so it is held to the Timeline's own
  # rule. Through the PUBLIC constructor, because that is the door every caller
  # uses and a freeze proved anywhere else proves nothing about it.
  describe "the address as a value" do
    it "is deeply frozen, block and all" do
      expect(Ractor.shareable?(reference)).to be(true)
      expect(Ractor.shareable?(reference.block)).to be(true)
      expect(Ractor.shareable?(reference.inline(png))).to be(true)
    end

    # The store refuses a bare hex digest from both its doors on purpose, so an
    # address written in a spelling it would not answer to is refused where it
    # is written rather than where it is looked up.
    it "refuses a digest the store would not answer to" do
      expect { Lain::Attachment::Reference.new(digest: digest.delete_prefix("blake3:"), media_type: "image/png") }
        .to raise_error(ArgumentError, /blake3/)
    end

    it "refuses a media type that is not an image's" do
      expect { Lain::Attachment::Reference.new(digest:, media_type: "text/plain") }
        .to raise_error(ArgumentError, %r{text/plain})
    end
  end

  describe "the request the provider is handed" do
    let(:sent) do
      dispatch(asking([reference.block]), [described_class.new(attachments: store)])
      mock.last_request
    end

    # The bytes are the last thing to be added and nothing downstream of here
    # mutates them, so a resolved request is as shareable as the addressed one
    # -- which is the mechanical statement of "this added no mutable state".
    it "is deeply frozen, straight out of the public construction path" do
      expect(Ractor.shareable?(sent)).to be(true)
    end

    # A retry frame, the stream-started signal and the journalled record all key
    # on the digest. Resolution is not a new turn, so it must not be a new
    # digest.
    it "answers the ADDRESSED request's digest and cache payload" do
      addressed = asking([reference.block])

      expect(sent.digest).to eq(addressed.digest)
      expect(Lain::Canonical.dump(sent.cache_payload)).not_to include(base64)
    end

    # The trap {Lain::Middleware::Env#to_json} is commented for: an un-delegated
    # lens serializes as its own object header, which is valid JSON carrying a
    # debug string, so a Journal takes it in silence. Refused rather than
    # delegated, because a `Data` answers `to_json` the same way and delegation
    # would inherit the trap one level down.
    it "refuses to be serialized, naming the record that should be written instead" do
      expect { sent.to_json }.to raise_error(Lain::Error, /RequestSent/)
    end

    it "answers the rest of the Request's surface as the one it stands for" do
      expect(sent.model).to eq("qwen3:4b")
      expect(sent.max_tokens).to eq(64)
      expect(sent.tools).to eq([])
      expect(sent.stream).to be(true)
    end
  end

  # Asserted AT THE ENCODER, because that is the only place the loss was
  # observable: the resolver, the Request and the Timeline all read normally
  # while Anthropic silently received a turn with no breakpoint on it.
  describe "a marked address, through to the wire" do
    # The real encoder, over the bare `#supports?` duck its includers are
    # Providers for.
    let(:anthropic) do
      Class.new do
        include Lain::Provider::AnthropicEncoding

        def supports?(_capability) = true
      end.new
    end

    def cache_controls(request)
      anthropic.encode(request)[:messages].sum { |message| message["content"].count { |b| b.key?("cache_control") } }
    end

    # {Lain::Context::CacheBreakpoints} marks a message's LAST block and a
    # screenshot turn is `[text, image]`, so the breakpoint lands on the address
    # itself. Losing it costs the full input price of the whole prefix with
    # nothing said -- which is the failure {Lain::Context}'s own docstring opens
    # by naming.
    it "reaches Anthropic as a marked INLINE block, so a screenshot turn still caches" do
      marked = reference.block.merge("cache" => true)
      dispatch(asking([{ "type" => "text", "text" => "what is on it" }, marked]),
               [described_class.new(attachments: store)])

      expect(cache_controls(mock.last_request)).to eq(1)
      expect(sent_image(mock.last_request)["source"]["data"].unpack1("m0")).to eq(png)
    end

    # The control, and what makes the count above a reading rather than a
    # coincidence: the same turn with no picture in it caches identically.
    it "caches the same turn with no picture in it identically" do
      dispatch(asking([{ "type" => "text", "text" => "what is on it", "cache" => true }]),
               [described_class.new(attachments: store)])

      expect(cache_controls(mock.last_request)).to eq(1)
    end

    # The chain is journalled and {Lain::Bench::Rewrites} compares it across
    # sessions, so an entry for a breakpoint the wire never carried is a false
    # claim in the record.
    it "claims a prefix chain the wire actually carries" do
      marked = reference.block.merge("cache" => true)
      dispatch(asking([{ "type" => "text", "text" => "what is on it" }, marked]),
               [described_class.new(attachments: store)])

      expect(mock.last_request.prefix_digests.size).to eq(cache_controls(mock.last_request))
    end
  end

  describe "an address nothing answers" do
    it "refuses loudly rather than sending a turn without its picture" do
      absent = Lain::Canonical.digest("bytes nobody stored")
      elsewhere = Lain::Attachment::Reference.new(digest: absent, media_type: "image/png")

      expect { dispatch(asking([elsewhere.block]), [described_class.new(attachments: store)]) }
        .to raise_error(Lain::Attachment::Store::Missing, /#{absent}/)
      expect(mock.call_count).to eq(0)
    end

    it "says which stack is unwired when no store was ever given to one" do
      expect { dispatch(asking([reference.block]), [described_class.new]) }
        .to raise_error(Lain::Attachment::Store::Missing, /no attachment store/)
    end
  end

  # The measurement that decided the design. Ten screenshots inline clear Lain's
  # own compaction threshold several times over; as addresses they cost about a
  # hundred bytes each, and the difference is the whole point of the reference.
  #
  # THE OTHER HALF OF THE TRADE, written here because this is where a reader
  # meets the happy number. With the resolver innermost, every byte-based measure
  # upstream of it sizes a 250 KB screenshot at about 155 bytes -- so
  # **compaction can never relieve image bulk**. The pictures do not enter
  # {Compaction::Head}'s reading, so nothing ever crosses threshold on their
  # account and no cut could drop them if it did: they are re-resolved from the
  # store on every later request, whole, for as long as the turn that refers to
  # them survives. The visible consequence is a wrong instruction: after a window
  # refusal the images caused, {Middleware::RequestBudget::Ask}'s moves still
  # tell the human "Make room with compaction", over an estimate whose
  # denominator excluded the bytes that overflowed. Relief comes from `/rewind`
  # or from a fresh chat, not from compaction. Not this card's defect -- the
  # measures are bytes-based and an image is not bytes-shaped, which
  # `SPIKE-images.md` lists in full -- but it is the cost of the shape this
  # example celebrates, and it belongs beside it.
  describe "ten screenshots' worth of history" do
    let(:shots) do
      Array.new(10) { |index| "\x89PNG#{index}#{"\xff" * 200_000}".force_encoding(Encoding::BINARY) }
    end

    def exchanges(blocks)
      blocks.flat_map.with_index do |block, index|
        [{ "role" => "user", "content" => [{ "type" => "text", "text" => "what is on shot #{index}" }, block] },
         { "role" => "assistant", "content" => [{ "type" => "text", "text" => "a page" }] }]
      end
    end

    def head_bytes(blocks)
      Lain::Compaction::Head.new(messages: exchanges(blocks), keep_last: 1).bytesize
    end

    it "stays under the compaction threshold as addresses, and blows past it as bytes" do
      shot_references = shots.map do |bytes|
        Lain::Attachment::Reference.new(digest: store.put(bytes), media_type: "image/png")
      end
      addresses = shot_references.map(&:block)
      inline = shot_references.zip(shots).map { |reference, bytes| reference.inline(bytes) }

      expect(head_bytes(addresses)).to be < Lain::CLI::Backend::DEFAULT_BYTE_THRESHOLD
      expect(head_bytes(inline)).to be > Lain::CLI::Backend::DEFAULT_BYTE_THRESHOLD
    end
  end

  # A child that did not resolve would send its parent's screenshot as the
  # address string -- a turn asking about a picture with no picture in it. The
  # `inherit` prefix is the shortest honest route to one: the child's first
  # render IS the parent's history, images and all.
  describe "a spawned child" do
    let(:child_provider) do
      Lain::Provider::Mock.new(responses: [Lain::Response.new(content: [{ "type" => "text", "text" => "a cat" }],
                                                              stop_reason: :end_turn)])
    end

    let(:parent) do
      Lain::Timeline.empty.commit(role: :user,
                                  content: [{ "type" => "text", "text" => "what is on it" }, reference.block])
    end

    let(:subagent) do
      Lain::Tools::Subagent.new(
        provider: child_provider, context_factory: -> { Lain::Context.new(model: "qwen3:4b", max_tokens: 64) },
        parent:, tool_middleware: ToolRegistry::UNGUARDED, attachments: store,
        toolset: Lain::Toolset.new([]),
        policy: Lain::Tool::SpawnPolicy.new(prefix: :inherit, posture: :schema, only: [])
      )
    end

    # THE invariant the whole design rests on, asserted at the door it turns on
    # rather than at a call site. Raw bytes through {Lain::Canonical} raise
    # loudly; base64 is valid UTF-8 and `normalize` interns every String with
    # `-@`, so a payload that reached it is held for the life of the process with
    # nothing said. The watch is on `normalize` ITSELF and not on a caller, because
    # `Request#with`, `Context#render` and `Request.new` are three doors onto one
    # room and watching any one proves only that door: `Data#with` does not go
    # through `.new` at all, which an earlier version of this example discovered
    # by staying green against exactly that regression. The two strings it counts
    # are named exactly -- the payload and the address -- so a THIRD large string
    # slipping through would not be seen here; the panel's own watchdog, which
    # records every receiver over 10 KB, is what says there is no third.
    #
    # The child is the subject because it renders the parent's history through
    # the real, pure {Lain::Context#render}. The positive halves keep the
    # negative from being vacuous: normalization happened, and the address itself
    # did pass through it.
    it "lets no payload reach Canonical.normalize, on the one path that renders a picture" do
      seen = { base64 => 0, digest => 0 }
      allow(Lain::Canonical).to receive(:normalize).and_wrap_original do |original, value|
        seen[value] += 1 if value.is_a?(String) && seen.key?(value)
        original.call(value)
      end

      spawn_child

      expect(seen[digest]).to be_positive
      expect(seen[base64]).to eq(0)
      expect(Lain::Attachment::Reference.each_in(child_provider.last_request.messages).to_a).to be_empty
    end

    def spawn_child
      subagent.call({ "prompt" => "describe it" },
                    Lain::Tool::Invocation.new(context: Lain::Session::Null.instance))
    end

    # {Lain::Tools::Subagent::ChildBuilder#config} copies the seam for a
    # grandchild, so the member has to be live rather than merely present: a
    # sibling card shipped a dead `config` member whose hand-back claimed it
    # carried state to a subtree.
    it "hands a grandchild the same store, through the copy #descend makes" do
      grandchild = subagent.descend(parent: -> { parent }, escalation: [Lain::Tools::AskHuman::HUMAN], ceiling: 1)

      expect(grandchild.seam.attachments).to be(store)
    end

    it "receives the bytes on the chain it inherited, not the address" do
      expect(spawn_child).to be_ok

      carried = Lain::Attachment::Reference.data_in(child_provider.last_request.messages)
      expect(carried.map { |data| data.unpack1("m0") }).to eq([png])
    end
  end
end
