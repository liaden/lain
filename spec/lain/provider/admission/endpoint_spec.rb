# frozen_string_literal: true

# The classifier behind {Provider::Admission}'s locality rule and its registry
# key. Split from the gate because they are two jobs -- counting callers, and
# reading URLs -- and because a review probe proved they have to AGREE: the
# canonical key must fold exactly the spellings `.local?` folds, or the keying
# defeats the rule. F26 reproduced through the real construction sites while
# they disagreed.
RSpec.describe Lain::Provider::Admission::Endpoint do
  # BOTH MISCLASSIFICATIONS ARE HARMFUL, IN OPPOSITE DIRECTIONS, and the table
  # below is written to keep that in view rather than to check a flag.
  #
  #   a FALSE POSITIVE (hosted read as local) gates a hosted endpoint at one in
  #   flight and SERIALISES concurrent subagents -- the throughput regression
  #   the locality rule exists to prevent;
  #
  #   a FALSE NEGATIVE (local read as hosted) hands it {Null} and LEAVES F26
  #   LIVE, silently -- nothing errors, two round trips simply overlap on a
  #   one-slot server again.
  #
  # Neither direction is the safe default, so neither may be relaxed to fix the
  # other. Three of these were live at review: the trailing-dot FQDN and the
  # bind-all address failed the F26 way, and the scheme-less hosted name failed
  # the subagent way.
  [["http://localhost:11434", "the canonical spelling"],
   ["http://LOCALHOST:11434", "an uppercased host"],
   ["http://localhost.:11434", "a trailing-dot FQDN, which is the same name rooted"],
   ["http://127.0.0.1:11434", "the v4 loopback"],
   ["http://127.5.5.5:11434", "anything in 127.0.0.0/8, which reaches one ollama"],
   ["http://127.0.0.53:11434", "systemd-resolved's address"],
   ["http://[::1]:11434", "the v6 loopback"],
   ["http://[::ffff:127.0.0.1]:11434", "a v4-mapped v6 loopback"],
   ["http://0.0.0.0:11434", "the unspecified address, which Backend::Endpoint accepts"],
   ["http://[::]:11434", "its v6 spelling"],
   ["http://ollama.localhost", "an RFC 6761 subdomain of localhost"],
   ["unix:///run/ollama.sock", "a unix socket"],
   ["/run/ollama.sock", "a bare filesystem path"],
   ["", "an empty endpoint"]].each do |endpoint, label|
    it "reads #{label} as local, because reading it as hosted would leave F26 live" do
      expect(described_class.local?(endpoint)).to be(true)
    end
  end

  [["https://api.anthropic.com", "a hosted name"],
   ["api.anthropic.com", "a hosted name with NO SCHEME, which URI reads as a bare path"],
   ["api.anthropic.com:443", "a host:port with no scheme, which URI reads as opaque"],
   ["http://10.255.255.1:11434", "a routable LAN address"],
   ["http://192.168.1.7:11434", "a private LAN address"],
   ["https://localhost.example.com", "a lookalike SUFFIX rather than a subdomain"],
   ["http://[fe80::1%25eth0]:11434", "a link-local v6 address"],
   ["http://myollama:11434", "a hostname that /etc/hosts may point at loopback"],
   ["http://[oh dear", "an endpoint that will not parse at all"]].each do |endpoint, label|
    it "reads #{label} as not local, because gating it would serialise subagents" do
      expect(described_class.local?(endpoint)).to be(false)
    end
  end

  # Named rather than left to the table: it is the one case where the honest
  # answer is the less safe-looking one. Resolving the name would be
  # synchronous I/O on the round-trip path, and the answer could change under a
  # running session.
  it "never resolves a hostname to decide, so /etc/hosts cannot change the answer" do
    expect(described_class.local?("http://myollama:11434")).to be(false)
  end

  describe ".canonical" do
    # Folded far enough to make one server one key, and NO FURTHER.
    it "folds every local spelling of one ollama onto a single key" do
      spellings = ["http://localhost:11434", "http://localhost:11434/", "http://LOCALHOST:11434",
                   "http://127.0.0.1:11434", "http://127.5.5.5:11434", "http://[::1]:11434",
                   "http://localhost.:11434", "http://0.0.0.0:11434"]

      expect(spellings.map { |endpoint| described_class.canonical(endpoint) }.uniq)
        .to eq(["http://localhost:11434"])
    end

    it "makes the port explicit, so a default port and a written one agree" do
      expect(described_class.canonical("https://api.anthropic.com"))
        .to eq(described_class.canonical("https://api.anthropic.com:443"))
    end

    it "keeps two ports apart, because they are two servers" do
      expect(described_class.canonical("http://localhost:11434"))
        .not_to eq(described_class.canonical("http://localhost:11435"))
    end

    # The same defect as the one folding fixes, pointing the other way: sharing
    # one slot between two services would be as wrong as splitting one server's.
    it "keeps two base paths apart, because they may be two services" do
      expect(described_class.canonical("http://localhost:11434/alpha"))
        .not_to eq(described_class.canonical("http://localhost:11434/beta"))
    end

    it "does not downcase a unix socket path, which is case-sensitive" do
      expect(described_class.canonical("unix:///run/Ollama.sock")).to include("Ollama")
    end

    it "keys an unparseable endpoint on its own text rather than raising" do
      expect(described_class.canonical("http://[oh dear")).to eq("http://[oh dear")
    end
  end
end
