# frozen_string_literal: true

# The Neovim PROTOCOL history, `{"9" => "...entry text..."}`, parsed out of the
# source because it lives in comments and no other reader exists. Shared rather
# than copied, so the files that sweep it cannot drift apart on what counts as
# an entry -- and so the anchor below has exactly one place to be wrong.
#
# Anchored on ANY entry line, not on the literal `# "2":` this started as. The
# panel inserted a `# "1":` above the "2" line carrying two false claims and the
# sweeps stayed green, because the extracted block was byte-identical: the entry
# fell entirely outside what was read. Backfilling is live practice in this block
# (entry "5" is one), so an entry written above the lowest number is a real shape,
# not a contrived one.
module ProtocolHistory
  SOURCE = File.expand_path("../../lib/lain/frontend/neovim.rb", __dir__)

  def protocol_history
    block = File.read(SOURCE)[/^[ \t]*# "\d+":.*?(?=^[ \t]*PROTOCOL = )/m]
    raise "no PROTOCOL history block in #{SOURCE}" if block.nil?

    entries = block.split(/^\s*# (?=")/).reject { |entry| entry.strip.empty? }
    entries.to_h { |entry| [entry[/\A"(\d+)":/, 1], entry] }
  end
end

RSpec.configure { |config| config.include ProtocolHistory }
