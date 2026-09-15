# frozen_string_literal: true

# {Lain::CLI::Command::Args} is the one parse `/survey`, `/review` and
# `/implement-epic` all read their line through now: quoting via
# {Shellwords}, and a named refusal for an unknown flag, a duplicated one, an
# extra positional, and an unterminated quote. What each COMMAND keeps for
# itself -- proven at its own spec, not here -- is the needs-value refusal,
# because only the command knows the noun ("a ref", "a scope") a human reads.
RSpec.describe Lain::CLI::Command::Args do
  def parse(text, **options)
    described_class.parse(text, name: "spec-command", usage: "/spec-command usage line", **options)
  end

  it "splits on whitespace, positionals first" do
    parsed = parse("one two", positionals: 2)

    expect(parsed.positionals).to eq(%w[one two])
  end

  it "keeps a quoted word whole, so a path with a space survives" do
    parsed = parse('"my notes"', positionals: 1)

    expect(parsed.positionals).to eq(["my notes"])
  end

  it "refuses an unterminated quote, naming the usage" do
    expect { parse('"my notes', positionals: 1) }
      .to raise_error(Lain::Error, /spec-command usage line/)
  end

  it "pairs a declared flag with the word after it" do
    parsed = parse("--scope by_directory", flags: %w[--scope], positionals: 0)

    expect(parsed.pairs).to eq({ "scope" => "by_directory" })
  end

  it "hands back nil for a declared flag given no value" do
    parsed = parse("--scope", flags: %w[--scope], positionals: 0)

    expect(parsed.pairs).to eq({ "scope" => nil })
  end

  it "records no entry at all for a flag never typed" do
    parsed = parse("", flags: %w[--scope], positionals: 0)

    expect(parsed.pairs).to eq({})
  end

  it "reads each declared switch by its own name" do
    parsed = parse("--unbounded", switches: %w[--unbounded --permissive], positionals: 0)

    expect(parsed.switches).to eq(unbounded: true, permissive: false)
  end

  it "refuses a flag this command does not declare, naming it" do
    expect { parse("--squash", flags: %w[--scope], positionals: 0) }
      .to raise_error(Lain::Error, %r{--squash is not a flag /spec-command can read})
  end

  # A duplicated flag used to be silently narrowed to its LAST value: a Hash
  # built from `[name, value]` pairs does that on its own, so this is the one
  # case a caller cannot recover by inspecting {#pairs} after the fact -- by
  # the time two entries share a key, only the second is still there.
  it "refuses a flag given twice, rather than quietly keeping the last" do
    expect { parse("--scope by_directory --scope by_extension", flags: %w[--scope], positionals: 0) }
      .to raise_error(Lain::Error, /--scope was given more than once/)
  end

  # A word past what a command declares used to vanish with no refusal at all.
  it "refuses a positional beyond what this command declares, naming it" do
    expect { parse("main extra", positionals: 1) }
      .to raise_error(Lain::Error, /extra/)
  end

  it "does not mistake a declared flag's value for a positional" do
    parsed = parse("main --scope by_directory", flags: %w[--scope], positionals: 1)

    expect(parsed.positionals).to eq(["main"])
  end

  it "does not mistake a declared switch for a positional" do
    parsed = parse("main --unbounded", switches: %w[--unbounded], positionals: 1)

    expect(parsed.positionals).to eq(["main"])
  end

  # The regression this chunk closes: an unknown flag reads as the mistake it
  # is, even beside an extra word that would otherwise be named instead.
  it "names the unknown flag ahead of an unrelated extra positional" do
    expect { parse("plans --wdith 1", flags: %w[--width], positionals: 0) }
      .to raise_error(Lain::Error, /--wdith/)
  end
end
