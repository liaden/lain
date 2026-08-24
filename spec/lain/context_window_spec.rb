# frozen_string_literal: true

RSpec.describe Lain::ContextWindow do
  describe "#window_tokens" do
    # A single-key table would pass even if the implementation ignored the
    # exact-match fast path and only ever scanned for family tokens -- the
    # queried name IS its own longest contained token either way. The decoy
    # "opus" entry with a WRONG value is what makes this genuinely exercise
    # "the full id resolves to its own entry", not just "something resolved".
    it "resolves an exact model name, not just its family" do
      book = described_class.new(windows: { "opus" => 500_000, "claude-opus-4-8" => 1_000_000 })
      expect(book.window_tokens("claude-opus-4-8")).to eq(1_000_000)
    end

    it "resolves a dated snapshot by its family token" do
      book = described_class.new(windows: { "sonnet" => 1_000_000 })
      expect(book.window_tokens("claude-3-5-sonnet-20241022")).to eq(1_000_000)
    end

    it "prefers the longest matching family token" do
      book = described_class.new(windows: {
                                   "opus" => 500_000,
                                   "claude-opus-4" => 1_000_000
                                 })
      expect(book.window_tokens("claude-opus-4-8")).to eq(1_000_000)
    end

    # Folded from .probe-TA3-adversarial.rb's "two family tokens" case: a
    # name containing BOTH "opus" and "sonnet" still resolves deterministically
    # via longest-token-wins rather than raising or drifting with Hash order.
    # Both orderings of the same table are asserted, because "deterministic" is
    # exactly the claim a single Hash literal cannot make -- and the answer is
    # pinned to the LONGER token ("sonnet"), not merely to some answer.
    it "resolves deterministically when a name contains two unrelated family tokens" do
      windows = { "opus" => 500_000, "sonnet" => 1_000_000 }

      expect(described_class.new(windows:).window_tokens("claude-opus-sonnet-mix")).to eq(1_000_000)
      expect(described_class.new(windows: windows.to_a.reverse.to_h).window_tokens("claude-opus-sonnet-mix"))
        .to eq(1_000_000)
    end

    # Folded from the adversarial probe: matching is case-sensitive, same as
    # PriceBook. Documented, not silently assumed.
    it "does not match a family token case-insensitively" do
      book = described_class.new(windows: { "opus" => 500_000 }, fallback: 42)
      expect(book.window_tokens("OPUS")).to eq(42)
    end

    # Folded from the adversarial probe: the docstring promises Symbol input.
    it "accepts a Symbol the same as the equivalent String" do
      book = described_class.new(windows: { "opus" => 500_000 })
      expect(book.window_tokens(:opus)).to eq(500_000)
    end

    # Review fix (Linus, SHOULD-FIX): legacy Anthropic ids resolved via the
    # bare "opus"/"sonnet" token over-estimated 5x against their real,
    # published 200,000-token window -- exactly the failure this card's own
    # escalation trigger names (compaction never fires). Pinned against the
    # real ids a `--model` flag can carry, using the bench's default table.
    describe "legacy Anthropic ids do not over-estimate" do
      subject(:book) { described_class.default }

      {
        "claude-opus-4-5" => 200_000,
        "claude-opus-4-1-20250805" => 200_000,
        "claude-sonnet-4-5-20250929" => 200_000,
        "claude-sonnet-4-20250514" => 200_000,
        "claude-3-5-sonnet-20241022" => 200_000
      }.each do |model, real_window|
        it "resolves #{model} to its real #{real_window}-token window" do
          expect(book.window_tokens(model)).to eq(real_window)
        end
      end

      # Regression pin: the new, more specific legacy keys must not shadow
      # the current-generation ids that still correctly resolve via the bare
      # family token.
      {
        "claude-opus-4-8" => 1_000_000,
        "claude-sonnet-4-6" => 1_000_000,
        "claude-haiku-4-5" => 200_000
      }.each do |model, real_window|
        it "still resolves current-generation #{model} to #{real_window}" do
          expect(book.window_tokens(model)).to eq(real_window)
        end
      end
    end

    # Review fix (Schneeman, SHOULD-FIX): a nil or blank model is a wiring
    # bug, not an unsupported provider -- CLAUDE.md's premise is that unknown
    # values fail loudly. This must hold on BOTH the fallback path (.default)
    # and the no-fallback path, and the message must name what was actually
    # passed (nil, not the coerced "").
    describe "a nil or blank model" do
      subject(:book) { described_class.default }

      it "raises for nil even though .default carries a fallback" do
        expect { book.window_tokens(nil) }.to raise_error(described_class::UnknownModel, /nil/)
      end

      it "raises for an empty string even though .default carries a fallback" do
        expect { book.window_tokens("") }.to raise_error(described_class::UnknownModel)
      end

      it "raises for a whitespace-only string even though .default carries a fallback" do
        expect { book.window_tokens("   ") }.to raise_error(described_class::UnknownModel)
      end

      it "raises for nil on a book with no fallback too" do
        strict = described_class.new(windows: {})
        expect { strict.window_tokens(nil) }.to raise_error(described_class::UnknownModel, /nil/)
      end
    end
  end

  # F3. A window is a denominator, and `:approaching_window` spends it on an
  # IRREVERSIBLE lossy rewrite -- so a caller has to be able to ask where the
  # number came from, not just what it is.
  #
  # THREE values. The two-valued reading ("measured" against "not measured")
  # is the latent regression the review panel caught:
  # {Lain::Provider#context_window_tokens} answers nil for every provider but
  # ollama, so a hosted run is measured against whatever the shipped table
  # says -- filing every table hit under "not measured" would switch
  # compaction off for every Anthropic and Bedrock arm in silence.
  #
  # "Hosted therefore published" holds only as far as the table does, which is
  # why the authority table below is enumerated by model id rather than
  # asserted as a rule: `claude-fable-5` and `claude-mythos-5` carry no tier
  # word, matched nothing, and were being measured against the 8,192 guess.
  describe "#resolve" do
    it "calls an exact table hit published" do
      book = described_class.new(windows: { "claude-opus-4-8" => 1_000_000 })
      resolution = book.resolve("claude-opus-4-8")

      expect(resolution.window_tokens).to eq(1_000_000)
      expect(resolution.provenance).to eq(described_class::PUBLISHED)
    end

    # A family-token match is still a real published number for a real model
    # id -- the dated snapshot resolving through "sonnet" is the ordinary
    # Anthropic case, not a degradation.
    it "calls a family-token match published too" do
      book = described_class.new(windows: { "sonnet" => 1_000_000 })

      expect(book.resolve("claude-3-5-sonnet-20241022").provenance).to eq(described_class::PUBLISHED)
    end

    it "calls the fallback branch guessed" do
      book = described_class.new(windows: {}, fallback: 8_192)
      resolution = book.resolve("qwen3:4b")

      expect(resolution.window_tokens).to eq(8_192)
      expect(resolution.provenance).to eq(described_class::GUESSED)
    end

    # The number is unchanged whichever way it was reached: this card
    # suppresses a trigger, it never raises the fallback (`context_window.rb`
    # ranks an over-estimate as worse than the crash it replaces).
    it "answers the same number #window_tokens does, on both branches" do
      book = described_class.new(windows: { "opus" => 500_000 }, fallback: 8_192)

      expect(book.resolve("claude-opus-4-8").window_tokens).to eq(book.window_tokens("claude-opus-4-8"))
      expect(book.resolve("qwen3:4b").window_tokens).to eq(book.window_tokens("qwen3:4b"))
    end

    # A malformed `windows:` entry must keep failing where it always failed --
    # loudly, at the guard that owns the denominator. Answering the fallback
    # and calling it a guess would turn an invalid table into a silent
    # degradation, and the number a reader then sees (8,192) is not the number
    # the table holds. `false` as well as `nil`, because the hazard is a
    # truthiness test rather than a nil test.
    describe "a table entry that is present but malformed" do
      [nil, false].each do |value|
        it "answers the entry verbatim as published rather than degrading, for #{value.inspect}" do
          book = described_class.new(windows: { "weird" => value }, fallback: 8_192)
          resolution = book.resolve("weird")

          expect(resolution.window_tokens).to be(value)
          expect(resolution.provenance).to eq(described_class::PUBLISHED)
        end

        it "still refuses loudly at the occupancy guard, for #{value.inspect}" do
          book = described_class.new(windows: { "weird" => value }, fallback: 8_192)

          expect { book.occupancy(1, model: "weird") }.to raise_error(ArgumentError, /window_tokens/)
        end
      end

      # The same for a family-token match, which resolves through the other
      # branch and so could regress independently.
      it "does not degrade a malformed entry reached by family token" do
        book = described_class.new(windows: { "sonnet" => nil }, fallback: 8_192)

        expect(book.resolve("claude-sonnet-4-6").window_tokens).to be_nil
      end
    end

    it "raises on a blank model rather than guessing, fallback or not" do
      expect { described_class.default.resolve("  ") }
        .to raise_error(described_class::UnknownModel, /wiring bug/)
    end

    it "raises on an unmatched model when no fallback is configured" do
      expect { described_class.new(windows: described_class::DEFAULTS).resolve("gpt-4") }
        .to raise_error(described_class::UnknownModel, /gpt-4/)
    end

    # The regression the panel caught, pinned by model id rather than argued
    # about: every id an Anthropic or a Bedrock arm actually runs under has to
    # come back authoritative, or `:approaching_window` stops firing for it.
    #
    # THE TRIPWIRE, and it only works if it is complete. Reviewed against the
    # current published catalogue: `claude-fable-5` and `claude-mythos-5` are
    # shipping first-party families that carry none of the opus/sonnet/haiku
    # tier words, so they matched nothing and were silently demoted to the
    # 8,192 guess -- a 1,000,000-token model measured against a floor. A table
    # missing the two ids already demoted is worse than no table, because it
    # reads as coverage. A new model family means a new row here.
    describe "the hosted arms keep their authority" do
      subject(:book) { described_class.default }

      %w[
        claude-opus-5
        claude-opus-4-8
        claude-sonnet-5
        claude-sonnet-4-6
        claude-haiku-4-5
        claude-opus-4-5
        claude-sonnet-4-20250514
        claude-fable-5
        claude-mythos-5
        claude-mythos-preview
        anthropic.claude-opus-4-8
        anthropic.claude-fable-5
        us.anthropic.claude-sonnet-4-6-v1:0
      ].each do |model|
        it "resolves #{model} as published, and so as authoritative" do
          expect(book.resolve(model).provenance).to eq(described_class::PUBLISHED)
          expect(book.resolve(model)).to be_authoritative
        end
      end

      # Authority alone is not enough: a published-but-wrong denominator is the
      # same defect wearing a better label, and the whole reason the two
      # missing families mattered is that their real window is 1M rather than
      # 8,192. Pinned as numbers so a wrong table row fails here, not in a
      # journal nobody reads.
      {
        "claude-fable-5" => 1_000_000,
        "claude-mythos-5" => 1_000_000,
        "claude-mythos-preview" => 1_000_000,
        "anthropic.claude-fable-5" => 1_000_000
      }.each do |model, window|
        it "measures #{model} against its real #{window}-token window" do
          expect(book.window_tokens(model)).to eq(window)
        end
      end
    end

    # T5. Every id here is one the cloud arm can actually be launched with, so
    # the numbers are pinned rather than merely the provenance: a PUBLISHED tag
    # on a wrong denominator is the fable/mythos defect wearing a better label.
    describe "the ollama cloud arm keeps its authority" do
      subject(:book) { described_class.default }

      {
        "gpt-oss:20b-cloud" => 128_000,
        "gpt-oss:120b-cloud" => 128_000,
        "qwen3.5:cloud" => 256_000,
        "qwen3.5:397b-cloud" => 256_000,
        "deepseek-v4-flash:cloud" => 1_000_000,
        "deepseek-v4-flash:0731-cloud" => 1_000_000,
        "deepseek-v4-flash:preview-cloud" => 1_000_000,
        "deepseek-v4-pro:cloud" => 1_000_000,
        "deepseek-v4-pro:0813-cloud" => 1_000_000,
        "deepseek-v4-pro:preview-cloud" => 1_000_000,
        "kimi-k3:cloud" => 1_000_000,
        "kimi-k2.7-code:cloud" => 256_000,
        "kimi-k2.6:cloud" => 256_000,
        "glm-5.2:cloud" => 976_000,
        "glm-5.1:cloud" => 198_000,
        "minimax-m2.7:cloud" => 200_000,
        "minimax-m3:cloud" => 512_000,
        "gemma4:cloud" => 256_000,
        "gemma4:31b-cloud" => 256_000,
        "nemotron-3-ultra:cloud" => 256_000,
        "nemotron-3-super:cloud" => 256_000,
        "nemotron-3-nano:30b-cloud" => 1_000_000,
        "mistral-large-3:675b-cloud" => 256_000
      }.each do |model, window|
        it "measures #{model} against its published #{window}-token window, authoritatively" do
          resolution = book.resolve(model)

          expect(resolution.window_tokens).to eq(window)
          expect(resolution.provenance).to eq(described_class::PUBLISHED)
          expect(resolution).to be_authoritative
        end
      end

      # The rows are a snapshot of somebody else's catalogue, so the honest
      # answer for an id it does not carry is still the floor -- publishing a
      # cloud section must not turn "-cloud" itself into evidence.
      it "still guesses for a cloud-shaped id nobody shipped" do
        resolution = book.resolve("some-model-nobody-shipped:7b-cloud")

        expect(resolution.window_tokens).to eq(described_class::CONSERVATIVE_FALLBACK)
        expect(resolution.provenance).to eq(described_class::GUESSED)
        expect(resolution).not_to be_authoritative
      end

      # T5's escalation trigger, kept as a live assertion rather than a
      # one-time eyeball: DEFAULTS is ONE table shared with the Anthropic arms
      # and `matched_key` scans it by substring, so a cloud id containing a
      # tier word would quietly take an Anthropic window.
      it "shares no substring with an Anthropic family token" do
        anthropic_tokens = Regexp.union(%w[opus sonnet fable mythos haiku])

        expect(described_class::CLOUD_WINDOWS.keys.grep(anthropic_tokens)).to be_empty
      end

      # The other direction of the same shared-table worry, and the one a
      # reader is likelier to get wrong: `matched_key` tests what the QUERIED
      # NAME contains, so a new key can only move an existing answer if some
      # Anthropic id contains that key.
      it "adds no key that an Anthropic id contains" do
        stolen = described_class::CLOUD_WINDOWS.keys.select do |id|
          described_class::ANTHROPIC_WINDOWS.keys.any? { |name| name.include?(id) }
        end

        expect(stolen).to be_empty
      end

      # The collision that is actually plausible is ollama-to-ollama, not
      # ollama-to-Anthropic: a bare "qwen3" or a bare "cloud" key would capture
      # the LOCAL arm's own default by the longest-token rule, handing a
      # 4-billion-parameter local runner a hosted model's denominator. The
      # local default is not covered by "every key that existed before" -- it
      # never had a key, it resolves by FALLBACK -- so it is pinned separately.
      it "leaves the local arm's default model resolving by fallback" do
        resolution = book.resolve(Lain::Provider::Ollama::DEFAULT_MODEL)

        expect(resolution.window_tokens).to eq(described_class::CONSERVATIVE_FALLBACK)
        expect(resolution.provenance).to eq(described_class::GUESSED)
      end

      it "adds no key that the local arm's default model contains" do
        capturing = described_class::CLOUD_WINDOWS.keys.select do |id|
          Lain::Provider::Ollama::DEFAULT_MODEL.include?(id)
        end

        expect(capturing).to be_empty
      end

      # The SHAPE rule, not another word-specific pin. The two examples above
      # catch the capture they were written for and nothing else: a probe
      # against this table added a bare "gpt-oss" key and all 136 examples
      # stayed green, while `--model gpt-oss:20b` -- a LOCAL runner -- then
      # resolved 128,000 tagged PUBLISHED and authoritative, which is precisely
      # the state that lets {Compaction::Source} spend an irreversible lossy
      # rewrite on a hosted model's denominator.
      #
      # So the invariant the comment on {described_class::CLOUD_WINDOWS} claims
      # is asserted as itself: every key names ONE tag of ONE model, and its tag
      # ends in "cloud". A bare family token has no colon and fails; a bare
      # "cloud" has no model and fails; "gpt-oss:20b" (local) fails. The keys
      # are listed in the failure so a bad row names itself.
      it "keys only ever name a single cloud tag, never a family token" do
        cloud_tag = /\A[^:\s]+:[^:\s]*cloud\z/
        malformed = described_class::CLOUD_WINDOWS.keys.grep_v(cloud_tag)

        expect(malformed).to be_empty
      end

      it "rejects the shapes that would capture a local model" do
        cloud_tag = /\A[^:\s]+:[^:\s]*cloud\z/

        expect(%w[gpt-oss gemma4 qwen3 cloud gpt-oss:20b].grep(cloud_tag)).to be_empty
      end
    end

    # AC 3, pinned as the whole pre-T5 table rather than a sample: the claim is
    # that NO Anthropic answer moved, and a sample cannot say that.
    describe "the rows that existed before the cloud section" do
      subject(:book) { described_class.default }

      {
        "opus" => 1_000_000,
        "sonnet" => 1_000_000,
        "fable" => 1_000_000,
        "mythos" => 1_000_000,
        "haiku" => 200_000,
        "claude-opus-4-5" => 200_000,
        "claude-opus-4-1" => 200_000,
        "claude-sonnet-4-5" => 200_000,
        "claude-sonnet-4-20250514" => 200_000,
        "claude-3-5-sonnet" => 200_000
      }.each do |model, window|
        it "answers #{model} with an unmoved #{window}, still published" do
          resolution = book.resolve(model)

          expect(resolution.window_tokens).to eq(window)
          expect(resolution.provenance).to eq(described_class::PUBLISHED)
        end
      end

      it "carries exactly those ten rows in its Anthropic half" do
        expect(described_class::ANTHROPIC_WINDOWS.keys).to contain_exactly(
          "opus", "sonnet", "fable", "mythos", "haiku", "claude-opus-4-5",
          "claude-opus-4-1", "claude-sonnet-4-5", "claude-sonnet-4-20250514",
          "claude-3-5-sonnet"
        )
      end
    end

    # The whole point of the value: only the guess is denied.
    it "is authoritative when probed or published, and not when guessed" do
      probed = described_class::WindowResolution.new(window_tokens: 32_768,
                                                     provenance: described_class::PROBED)
      published = described_class::WindowResolution.new(window_tokens: 200_000,
                                                        provenance: described_class::PUBLISHED)
      guessed = described_class::WindowResolution.new(window_tokens: 8_192,
                                                      provenance: described_class::GUESSED)

      expect([probed, published].map(&:authoritative?)).to eq([true, true])
      expect(guessed).not_to be_authoritative
    end

    # CLAUDE.md's premise throughout: an unknown value fails loudly rather
    # than degrading. A typo'd provenance that merely read as "not guessed"
    # would silently re-authorise the rewrite this card exists to deny.
    it "refuses a provenance it does not know" do
      expect { described_class::WindowResolution.new(window_tokens: 8_192, provenance: :measured) }
        .to raise_error(ArgumentError, /provenance/)
    end

    it "is frozen and Ractor-shareable" do
      expect(described_class.default.resolve("claude-opus-4-8")).to be_deeply_frozen
    end
  end

  describe ".default" do
    subject(:book) { described_class.default }

    # The unknown ollama-style id ("qwen3:4b") is pinned to the actual
    # CONSERVATIVE_FALLBACK by "measures a model the book does not carry against
    # the conservative fallback" under #occupancy below, which resolves the
    # window through this same path and names the number rather than its class.
    it "is deeply frozen and Ractor-shareable" do
      expect(book).to be_deeply_frozen
    end
  end

  # The ratio {Compaction::Need::ApproachingWindow} computed inside its own
  # #fired? and threw away, made readable. The book owns the denominator, so
  # the book is where a model name becomes an occupancy.
  describe "#occupancy" do
    it "reports the fraction of the model's window a turn's tokens fill" do
      book = described_class.new(windows: { "tiny" => 8192 })

      expect(book.occupancy(4096, model: "tiny").ratio).to eq(0.5)
    end

    it "is absence, not zero, before any turn has been observed" do
      expect(described_class.default.occupancy(nil, model: "claude-opus-4-8").ratio).to be_nil
    end

    it "measures a model the book does not carry against the conservative fallback" do
      occupancy = described_class.default.occupancy(4096, model: "qwen3:4b")

      expect(occupancy.window_tokens).to eq(described_class::CONSERVATIVE_FALLBACK)
      expect(occupancy.ratio).to eq(0.5)
    end

    # The window resolves BEFORE absence is considered, so the blank-model
    # wiring bug is loud on turn zero rather than on the first turn that
    # happens to carry usage.
    it "still raises on a blank model, turn or no turn" do
      expect { described_class.default.occupancy(nil, model: nil) }
        .to raise_error(described_class::UnknownModel, /wiring bug/)
    end

    # ...and having resolved it, it KEEPS it. A pre-first-turn status line
    # renders "-- / 1,000,000" off this, so throwing the denominator away
    # because there is no numerator yet would send the caller back to the book
    # for a number the book just computed.
    it "keeps the window it resolved even with no turn to measure against it" do
      none = described_class.default.occupancy(nil, model: "claude-opus-4-8")

      expect(none.window_tokens).to eq(1_000_000)
      expect(none.used_tokens).to be_nil
    end

    it "refuses to report an occupancy against a non-positive window" do
      book = described_class.new(windows: { "broken" => 0 })

      expect { book.occupancy(1, model: "broken") }.to raise_error(ArgumentError, /window_tokens/)
    end
  end

  describe Lain::ContextWindow::Occupancy do
    it "answers the detector's question with the same numbers it answers a human's" do
      occupancy = described_class.of(used_tokens: 900, window_tokens: 1000)

      expect(occupancy.ratio).to eq(0.9)
      expect(occupancy.at_least?(0.9)).to be(true)
      expect(occupancy.at_least?(0.91)).to be(false)
    end

    # Absence is not a zero-token context: a zero would clear every threshold
    # from below, so `at_least?(0.0)` is the case that tells them apart.
    it "never fires, and has no ratio, when there is no usage to measure" do
      none = described_class.of(used_tokens: nil, window_tokens: 1000)

      expect(none.ratio).to be_nil
      expect(none.at_least?(0.0)).to be(false)
      expect(described_class.of(used_tokens: 0, window_tokens: 1000).at_least?(0.0)).to be(true)
    end

    # A Null Object that answers half the duck is not substitutable, which is
    # the only thing a Null Object is for -- {Sink::Null} is the exemplar. Every
    # reader a real reading answers, absence answers too.
    it "substitutes for a real reading across the whole duck, not half of it" do
      none = described_class.of(used_tokens: nil, window_tokens: 1000)
      real = described_class.of(used_tokens: 900, window_tokens: 1000)

      expect(none.window_tokens).to eq(1000)
      expect(none.used_tokens).to be_nil
      expect(none.to_h).to eq(used_tokens: nil, window_tokens: 1000)
      expect(none.to_h.keys).to eq(real.to_h.keys)
    end

    # {Occupancy.window!} refuses a NaN denominator BECAUSE a NaN ratio breaks
    # `==` for a caller holding two readings. Absence must not break the same
    # thing unconditionally: a status line redrawing on `reading != @last`
    # would repaint forever before the first turn.
    it "gives absence the value equality a real reading has" do
      first = described_class.of(used_tokens: nil, window_tokens: 1000)
      second = described_class.of(used_tokens: nil, window_tokens: 1000)

      expect(first).to eq(second)
      expect(first).to eql(second)
      expect(first.hash).to eq(second.hash)
      expect([first, second].uniq.size).to eq(1)
      expect({ first => :drawn }.fetch(second)).to eq(:drawn)
    end

    it "tells absence against one window from absence against another" do
      expect(described_class.of(used_tokens: nil, window_tokens: 1000))
        .not_to eq(described_class.of(used_tokens: nil, window_tokens: 2000))
    end

    it "is never equal to a real reading, not even a zero-token one" do
      expect(described_class.of(used_tokens: nil, window_tokens: 1000))
        .not_to eq(described_class.of(used_tokens: 0, window_tokens: 1000))
    end

    it "deconstructs for pattern matching the way a real reading does" do
      absent = described_class.of(used_tokens: nil, window_tokens: 1000)

      case absent
      in { used_tokens: nil, window_tokens: Integer => window }
        expect(window).to eq(1000)
      end
    end

    it "is frozen and Ractor-shareable, absent or not" do
      expect(described_class.of(used_tokens: nil, window_tokens: 1000)).to be_deeply_frozen
      expect(described_class.of(used_tokens: 900, window_tokens: 1000)).to be_deeply_frozen
    end

    # `.of` establishes the invariant; `.new` and `#with` are doors it does not
    # watch, and a nil that slips through one of them fails late and far away
    # (`undefined method 'fdiv' for nil`, from inside a frozen value). The guard
    # belongs at construction, where the house rule is loud failure.
    describe "the doors .of is not" do
      it "refuses a nil used_tokens through .new" do
        expect { described_class.new(used_tokens: nil, window_tokens: 100) }
          .to raise_error(ArgumentError, /used_tokens/)
      end

      it "refuses a nil used_tokens through Data#with" do
        expect { described_class.of(used_tokens: 900, window_tokens: 1000).with(used_tokens: nil) }
          .to raise_error(ArgumentError, /used_tokens/)
      end

      it "still allows #with to rewrite a real reading" do
        expect(described_class.of(used_tokens: 900, window_tokens: 1000).with(used_tokens: 500).ratio).to eq(0.5)
      end

      # Neither of these raises on its own: they read as Infinity and NaN, and
      # a NaN ratio also breaks `==` for a caller comparing two readings.
      it "refuses a zero window, which would otherwise read as Infinity or NaN" do
        expect { described_class.of(used_tokens: 1, window_tokens: 0) }
          .to raise_error(ArgumentError, /window_tokens/)
        expect { described_class.of(used_tokens: 0, window_tokens: 0) }
          .to raise_error(ArgumentError, /window_tokens/)
      end

      it "refuses a negative window, absent or not" do
        expect { described_class.of(used_tokens: 1, window_tokens: -1) }
          .to raise_error(ArgumentError, /window_tokens/)
        expect { described_class.of(used_tokens: nil, window_tokens: -1) }
          .to raise_error(ArgumentError, /window_tokens/)
      end
    end
  end

  describe "a book built without a fallback" do
    # A `windows: {}` table would make ANY unmatched name raise trivially --
    # even a broken token scan that never excludes anything correctly would
    # pass this. Using the real, populated default table proves "gpt-4"
    # genuinely matches none of the real family/legacy tokens, not just that
    # an empty hash has nothing to offer.
    it "raises UnknownModel naming the model, against the populated default table" do
      book = described_class.new(windows: Lain::ContextWindow::DEFAULTS)
      expect { book.window_tokens("gpt-4") }
        .to raise_error(described_class::UnknownModel, /gpt-4/)
    end
  end
end
