# frozen_string_literal: true

require "pathname"

# Mechanical enforcement of one rule: a Null that exists only so a spec can
# construct something must not be reachable from `lib/`, and above all must not
# be a keyword-argument DEFAULT on a production constructor.
#
# What a default like that costs is not tidiness. It is that a wiring omission
# assembles cleanly: the run gets a board that gates nothing, or a queue nobody
# drains, and the only evidence is a sentence in a comment saying the state is
# "not sanctioned". Requiring the keyword instead turns the omission into an
# ArgumentError at the construction site, which is where it can be read.
# `ToolRegistry::UNGUARDED` is the standing precedent and says the same thing
# about a child's tool guard.
#
# NOT A HAND-KEPT LIST. The subjects are whatever `spec/support/nulls/` has put
# on {SpecNulls}, read back at run time, so a Null relocated there tomorrow is
# covered tomorrow. The check is a superset of "never a default": `lib/` may not
# name one of these AT ALL, which is both simpler to state and impossible to
# satisfy accidentally -- a production file cannot even require the file that
# defines them.
#
# The corollary a reader should know before adding one: the name has to be
# distinctive enough to search `lib/` for. A Null named `Null` would match
# hundreds of legitimate lines and redden this spec on the day it lands, which
# is the intended answer rather than a false positive to suppress.
module LibNullDefaults
  ROOT = Pathname.new(File.expand_path("..", __dir__))

  # `exe/lain` is production wiring too -- a thousand lines of it -- so a
  # relocated Null defaulted there would be as wrong as one in lib/ and, until
  # this read both roots, as invisible.
  SCANNED = [ROOT.glob("lib/**/*.rb"), ROOT.glob("exe/*")].freeze

  # @return [Array<String>] every constant spec/support/nulls put on SpecNulls
  def self.relocated = SpecNulls.constants.map(&:to_s).sort

  # @return [Hash{String=>Array<String>}] name => "path:line" for each mention
  def self.mentions
    relocated.to_h { |name| [name, sites_naming(name)] }
  end

  def self.sites_naming(name)
    pattern = /\b#{Regexp.escape(name)}\b/
    ruby_files.flat_map { |path| lines_matching(path, pattern) }
  end

  def self.ruby_files = SCANNED.flatten.select(&:file?).sort

  def self.lines_matching(path, pattern)
    path.each_line.with_index(1)
        .select { |line, _number| pattern.match?(line) }
        .map { |_line, number| "#{path.relative_path_from(ROOT)}:#{number}" }
  end
end

RSpec.describe "test-only Nulls" do
  # The vacuity guard. Every assertion below is over this list, so an empty one
  # would make the whole file pass while checking nothing -- which is exactly
  # the shape `bin/spec-census` exists to report.
  it "are enumerated from spec/support/nulls rather than from a list kept here" do
    expect(LibNullDefaults.relocated).not_to be_empty
  end

  it "are named nowhere in lib/ or exe/, so no production constructor can default to one" do
    named = LibNullDefaults.mentions.reject { |_name, sites| sites.empty? }

    expect(named).to eq({}), lambda {
      named.map { |name, sites| "SpecNulls::#{name} is named in production code at #{sites.join(", ")}" }.join("\n")
    }
  end
end
