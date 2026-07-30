# frozen_string_literal: true

RSpec.describe Lain::Provider::ErrorWrapping do
  # The four backends over the vendored transport, each with the base its own
  # error family must root at. The Embedder is the reason `.under` takes a
  # parameter at all: `rescue Embedder::Error` has to keep catching every
  # embedding failure, so its pair cannot descend from Lain::Error directly.
  # A class method, not a constant: a constant here would leak onto Object.
  def self.families
    { Lain::Provider::Anthropic => Lain::Error,
      Lain::Provider::Bedrock => Lain::Error,
      Lain::Provider::Ollama => Lain::Error,
      Lain::Embedder::Ollama => Lain::Embedder::Error }
  end

  # A vendored transport error in its two shapes: one built from a response
  # object that answers #status, one built from a bare String (Error#initialize
  # shifts a String into `message` and leaves `response` nil).
  def http_error(status: nil)
    return Lain::Provider::HTTP::Error.new("no response at all") if status.nil?

    Lain::Provider::HTTP::Error.new(Struct.new(:status, :body).new(status, "boom"), "boom")
  end

  def includer_under(base)
    Class.new do
      include Lain::Provider::ErrorWrapping.under(base)

      # wrap_error is private in every real includer; this is the one public
      # door the examples drive it through.
      def wrap(error) = wrap_error(error)
    end
  end

  describe ".under" do
    it "defines APIError and APIStatusError scoped to the includer, rooted at the given base" do
      klass = includer_under(Lain::Embedder::Error)

      expect(klass.const_defined?(:APIError, false)).to be(true)
      expect(klass::APIError.superclass).to eq(Lain::Embedder::Error)
      expect(klass::APIStatusError.superclass).to eq(klass::APIError)
    end

    # The whole reason this is a factory rather than a module with two constants
    # in it: `rescue Provider::ErrorWrapping::APIError` must not exist, because
    # it would catch all four backends at once.
    it "does not define the pair on the shared module itself" do
      expect(described_class.const_defined?(:APIError, false)).to be(false)
      expect(described_class.const_defined?(:APIStatusError, false)).to be(false)
    end

    it "gives two includers of the same base their OWN unrelated pairs" do
      one = includer_under(Lain::Error)
      other = includer_under(Lain::Error)

      expect(one::APIError).not_to eq(other::APIError)
      expect(one.new.wrap(http_error(status: 500))).not_to be_a(other::APIError)
    end

    # `wrap_error` was private in all four hand-written copies. The two class
    # readers are new and must be private too: they exist only so ONE
    # `#wrap_error` body can reach each includer's own pair, and a public
    # `provider.api_error_class` would be API surface nobody asked for.
    it "keeps every method it adds private" do
      klass = includer_under(Lain::Error)

      expect(klass.private_instance_methods)
        .to include(:wrap_error, :wrapping_errors, :api_error_class, :api_status_error_class)
      expect(klass.public_instance_methods)
        .not_to include(:wrap_error, :wrapping_errors, :api_error_class, :api_status_error_class)
    end
  end

  describe "#wrap_error" do
    subject(:wrapper) { includer_under(Lain::Error).new }

    it "lifts the status out of a response-bearing error" do
      wrapped = wrapper.wrap(http_error(status: 529))

      expect(wrapped).to be_a(wrapper.class::APIStatusError)
      expect(wrapped.status).to eq(529)
      expect(wrapped.message).to eq("boom")
    end

    it "wraps a response-less error as the plain APIError" do
      wrapped = wrapper.wrap(http_error)

      expect(wrapped).to be_a(wrapper.class::APIError)
      expect(wrapped).not_to be_a(wrapper.class::APIStatusError)
      expect(wrapped.message).to eq("no response at all")
    end
  end

  describe "the four backends that include it" do
    families.each do |backend, base|
      it "gives #{backend} a nested APIError rooted at #{base}" do
        expect(backend.const_get(:APIError).superclass).to eq(base)
        expect(backend.const_get(:APIStatusError)).to be < backend.const_get(:APIError)
      end
    end

    # Nested identity is the contract every existing spec rescues by. If the
    # collapse had hoisted one shared pair, `rescue Provider::Ollama::APIError`
    # would start catching a Bedrock failure -- and a bench arm's error
    # attribution would silently stop meaning anything.
    it "shares no APIError between any two of them" do
      backends = self.class.families.keys
      pairs = backends.map { |backend| backend.const_get(:APIError) }

      expect(pairs.uniq.size).to eq(backends.size)
    end

    # `.under` returns an anonymous Module, so `ancestors` shows one
    # `#<Module:0x…>` entry and `include?(ErrorWrapping)` is false. The
    # answerable form of "does this class have error wrapping?" is the named
    # submodule, and this pins it so the question has an answer that does not
    # depend on reading `.under`.
    families.each_key do |backend|
      it "answers include?(ErrorWrapping::Wrapping) for #{backend}" do
        expect(backend.include?(Lain::Provider::ErrorWrapping::Wrapping)).to be(true)
      end
    end
  end

  # THE DRIFT GUARD. Two of these four arms went missing for months, and they
  # went missing because each backend wrote its own rescue block: the absence of
  # a copy is invisible, while the presence of a wrong one is not. So this walks
  # all four and drives ONE round trip per shape through a transport that raises,
  # asserting the wrapped type -- no webmock, no network, no per-backend spec to
  # forget. A fifth backend is caught the moment it is added to this table, and
  # `#complete`/`#embed` losing the shared wrapper reddens here immediately.
  describe "arm coverage across every backend (drift guard)" do
    # One driver per backend, because the round trip is named differently
    # (#complete vs #embed) and each constructor needs its own credentials.
    def self.round_trips
      request = Lain::Request.new(model: "m", max_tokens: 8, stream: false,
                                  messages: [{ role: "user", content: "hi" }])
      { Lain::Provider::Anthropic =>
          ->(t) { Lain::Provider::Anthropic.new(transport: t, api_key: "k").complete(request) },
        Lain::Provider::Bedrock =>
          ->(t) { Lain::Provider::Bedrock.new(transport: t, api_key: "k", region: "us-east-1").complete(request) },
        Lain::Provider::Ollama =>
          ->(t) { Lain::Provider::Ollama.new(transport: t).complete(request) },
        Lain::Embedder::Ollama =>
          ->(t) { Lain::Embedder::Ollama.new(transport: t).embed(%w[a]) } }
    end

    # Answers every round trip any of the four might ask for, by raising. The
    # `**` matters: Anthropic's #sync_post is called with a `frame:` kwarg.
    def raising_transport(error)
      Class.new do
        define_method(:sync_post) { |*, **| raise error }
        define_method(:stream) { |*, **, &_block| raise error }
        define_method(:embed_post) { |*, **| raise error }
      end.new
    end

    round_trips.each do |backend, round_trip|
      # The arm that was missing on Bedrock and Embedder::Ollama: a
      # connection-level failure never reaches the vendored ErrorMiddleware, so
      # exhausted retries re-raise a bare Faraday class.
      it "#{backend} contains a Faraday::Error in its own APIError" do
        expect { round_trip.call(raising_transport(Faraday::ConnectionFailed.new("dropped"))) }
          .to raise_error(backend.const_get(:APIError)) do |wrapped|
            expect(wrapped).not_to be_a(backend.const_get(:APIStatusError))
            expect(wrapped.cause).to be_a(Faraday::ConnectionFailed)
          end
      end

      it "#{backend} lifts the status out of a Provider::HTTP::Error" do
        response = Struct.new(:status, :body).new(529, "overloaded")

        expect { round_trip.call(raising_transport(Lain::Provider::HTTP::Error.new(response, "overloaded"))) }
          .to raise_error(backend.const_get(:APIStatusError)) do |wrapped|
            expect(wrapped.status).to eq(529)
          end
      end

      it "#{backend} keeps both wrapped errors inside Lain::Error" do
        expect { round_trip.call(raising_transport(Faraday::ConnectionFailed.new("dropped"))) }
          .to raise_error(Lain::Error)
      end
    end
  end
end
