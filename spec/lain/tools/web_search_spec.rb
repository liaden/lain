# frozen_string_literal: true

RSpec.describe Lain::Tools::WebSearch do
  # The tool is credential-agnostic: it owns no API key or endpoint. A backend
  # is injected; the tool only renders whatever ranked results it returns. Specs
  # inject a static backend -- never a live search API.
  def result(title:, url:, snippet: nil)
    Lain::Tools::WebSearch::Result.new(title:, url:, snippet:)
  end

  subject(:tool) { described_class.new(backend:) }

  let(:backend) do
    hits = [result(title: "Frozen string literals", url: "https://ruby-doc.org/frozen",
                   snippet: "magic comment"),
            result(title: "String#freeze", url: "https://ruby-doc.org/freeze")]
    ->(_query) { hits }
  end

  it "returns titled, linked results from the injected backend" do
    result = tool.call({ query: "ruby frozen string" }, nil)
    expect(result).to be_ok
    expect(result.content).to include("Frozen string literals")
    expect(result.content).to include("https://ruby-doc.org/frozen")
    expect(result.content).to include("String#freeze")
    expect(result.content).to include("https://ruby-doc.org/freeze")
  end

  it "passes the query through to the backend" do
    seen = []
    tool = described_class.new(backend: ->(query) { seen << query and [] })
    tool.call({ query: "medical literature" }, nil)
    expect(seen).to eq(["medical literature"])
  end

  it "reports no results as an ok Result rather than an empty crash, distinct from the unconfigured case" do
    tool = described_class.new(backend: ->(_query) { [] })
    result = tool.call({ query: "nothing matches" }, nil)
    expect(result).to be_ok
    expect(result.content).to match(/no results/i)
    expect(result.content).not_to match(/no search backend is configured/i)
  end

  it "surfaces a raising backend as a loud error Result, not a crash" do
    tool = described_class.new(backend: ->(_query) { raise "backend down" })
    result = tool.call({ query: "boom" }, nil)
    expect(result).to be_error
    expect(result.content).to include("backend down")
  end

  describe "the default (unconfigured) backend" do
    # Ships with a Null backend so the tool is constructible without wiring in a
    # concrete provider. F2: an unconfigured search must say so, distinguishably
    # from a configured backend that searched and found nothing (folded into the
    # "reports no results" example above) -- and it must read as NON-RETRYABLE
    # and name the QUERY: the QA run's failure mode was six retries against a
    # message that read like it might work next time, and an interleaved
    # transcript needs to tie this result back to the call that produced it.
    it "says no backend is configured, names the query, and reads as non-retryable" do
      result = described_class.new.call({ query: "anything" }, nil)
      expect(result).to be_ok
      expect(result.content).to match(/no search backend is configured/i)
      expect(result.content).not_to match(/no results for/i)
      expect(result.content).to include('"anything"')
      expect(result.content).to match(/session|unavailable/i)
    end
  end

  describe "immunity to a backend result that overrides #equal?" do
    # The review's Fix 1: `raw.equal?(NOT_CONFIGURED)` calls `#equal?` on the
    # UNTRUSTED value the backend returned, so a result that overrides
    # `#equal?` to always answer true gets misreported as "unconfigured" even
    # though it is a real hit from a real, configured backend. The fix swaps
    # the receiver -- `NOT_CONFIGURED.equal?(raw)` -- so the identity check
    # dispatches on the module's own frozen constant, which never overrides
    # `#equal?`, rather than on whatever the backend handed back.
    let(:liar) do
      Object.new.tap do |hit|
        def hit.equal?(_other) = true
        def hit.title = "a real hit"
        def hit.url = "https://example.com"
      end
    end

    it "does not misreport a real hit as an unconfigured backend, even when the hit lies about #equal?" do
      tool = described_class.new(backend: ->(_query) { liar })
      result = tool.call({ query: "q" }, nil)
      expect(result.content).not_to match(/no search backend is configured/i)
      expect(result.content).to include("a real hit")
    end
  end

  describe "the unconfigured sentinel" do
    # Fix 3: the previous version of this example (`expect(NOT_CONFIGURED).not_to
    # eq([])`) is true of nearly every object in Ruby and would pass just as
    # happily if the sentinel were `1` or `:nope` -- it pinned nothing about
    # unconstructibility. These assert the actual properties that matter: Null
    # always answers the same object (identity, not a fresh look-alike each
    # call), and an ordinary backend result -- empty, a real hit, or even a
    # second unrelated `Object.new.freeze` of the exact same shape -- never
    # reads as "unconfigured".
    it "is what Backend::Null returns, every time, by identity" do
      a = Lain::Tools::WebSearch::Backend::Null.call("q1")
      b = Lain::Tools::WebSearch::Backend::Null.call("q2")
      expect(a).to equal(b)
    end

    it "is never produced by an ordinary backend result" do
      look_alike = Object.new.freeze
      ordinary_results = [[], [result(title: "t", url: "https://example.com")], look_alike]
      ordinary_results.each do |value|
        tool = described_class.new(backend: ->(_query) { value })
        content = tool.call({ query: "q" }, nil).content
        expect(content).not_to match(/no search backend is configured/i)
      end
    end
  end
end
