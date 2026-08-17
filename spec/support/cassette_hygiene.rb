# frozen_string_literal: true

require "socket"
require "yaml"

# What must never survive into a committed cassette, and where the answer is
# enforced.
#
# A cassette is committed YAML holding FULL request and response bodies, and it
# is permanent, replayable and invisible once merged. So this is a REPOSITORY
# rule, not one card's checklist -- it lives here, under its own name, because
# every cassette recorded after the first is swept by it too.
#
# == It is enforced in TWO places, and they are not the same instrument
#
#   * spec/support/vcr_configuration.rb's `before_record` calls {.redact}, so a
#     local blob path cannot be WRITTEN in the first place. That is the gate.
#   * The guard examples in spec/lain/provider/ollama_recorded_spec.rb call
#     {.findings_in}. That is the BACKSTOP: it catches every shape the gate does
#     not redact, and it catches them on the next full run rather than at the
#     moment of recording -- a recording pass driven with `-e` filters that group
#     out entirely, and `config.order = :random` otherwise decides whether it
#     reads pre- or post-recording bytes.
#
# == Why the shapes are generic, and not this box's
#
# The first version of this asked `Dir.home` and `Socket.gethostname` of the
# PROCESS RUNNING THE SUITE -- which is never the machine that recorded. Planted
# with realistic leak shapes it let 13 of 17 through: another operator's home
# directory, a macOS `/Users/...`, a Windows profile path, `/srv/models/...`, an
# `OLLAMA_MODELS` path with no `blobs/` segment, IPv4 literals, a MAC address, a
# `Set-Cookie`, an `X-Api-Key`, a `Bearer` inside a body. The machine-local arms
# are kept -- they are strictly extra information -- but they are the last two,
# not the whole rule.
#
# == Headers are checked by NAME; bodies are not checked for header words
#
# `/api/show` embeds the model's entire licence, and Apache 2.0 says "authorized"
# four times. A `grep -i authoriz` over the body reds on a cassette containing no
# credential at all -- four characters away, in the very first model recorded. So
# the YAML is parsed: header NAMES are tested for credential shapes, bodies and
# URIs for path/address/token shapes, and neither test sees the other's text.
module CassetteHygiene
  # What {.redact} writes in place of a local blob path. Chosen to contain no
  # `/` and no `blobs/`, so the redacted form cannot match the shape that
  # produced it.
  BLOB_PLACEHOLDER = "<OLLAMA_BLOB>"

  # `/api/show`'s `modelfile` quotes this: an absolute path into whatever
  # directory the recording box keeps its model blobs in.
  BLOB_PATH = %r{/[\w.-]+(?:/[\w.-]+)*/blobs/sha256-[0-9a-f]+}

  # Shapes tested against BODIES and URIs, in report order. Every one of them is
  # a shape that appeared in the planted-leak sweep.
  #
  # The IPv4 arm deliberately spares loopback and `0.0.0.0`: a cassette recorded
  # against a local server names one of those by construction, and a guard that
  # reds on `127.0.0.1` would be turned off rather than fixed. `localhost` is not
  # an address shape at all.
  CONTENT_SHAPES = {
    "local blob path" => BLOB_PATH,
    "absolute local path" => %r{/(?:home|Users|root|mnt|srv|opt|media)/[\w.-]+},
    "windows profile path" => /[A-Za-z]:\\(?:Users|Documents and Settings)\\/i,
    "ipv4 literal" => /\b(?!127\.)(?!0\.0\.0\.0\b)(?:\d{1,3}\.){3}\d{1,3}\b/,
    "mac address" => /\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b/i,
    "bearer token" => /\bBearer\s+[\w.-]{8,}/i,
    "api key literal" => /\b(?:sk|xoxb|ghp)-[A-Za-z0-9\-_]{16,}/
  }.freeze

  # The shapes whose MATCH must not be echoed into a failure message. Naming the
  # shape and the offset is the whole requirement; reproducing the token in a
  # test report would move the secret rather than find it.
  SECRET_SHAPES = ["bearer token", "api key literal"].freeze

  # Header NAMES that carry a credential. `api[-_]?key` with no anchor at the
  # front is what covers `x-api-key`, `anthropic-api-key` and `apikey` in one
  # arm.
  CREDENTIAL_HEADER = /\A(?:proxy-)?authorization\z|\Aset-cookie\z|\Acookie\z|\Ax-auth-token\z|api[-_]?key\z/i

  # A machine-local token shorter than this matches half of any file, so it is
  # not worth asking. `HOME=/` is the case that forced the floor: `Dir.home`
  # is then `"/"`, every cassette contains `/`, and every cassette reds -- a real
  # state in a minimal container with no passwd entry.
  MIN_LOCAL_TOKEN = 6

  # A hostname floor of its own, lower because a hostname is matched as a whole
  # WORD rather than as a path prefix. The floor alone is not enough and the
  # boundary is not decoration: measured, a box called `arch` -- exactly at this
  # floor -- matched inside `general.architecture` in the committed `/api/show`
  # body, i.e. red on a clean cassette, on somebody else's machine, which is how
  # a guard gets deleted instead of fixed.
  MIN_LOCAL_HOSTNAME = 4

  # A cassette recorded against a local server names this by construction, so a
  # box called `localhost` must not arm the hostname shape.
  IGNORED_HOSTNAMES = %w[localhost localhost.localdomain].freeze

  # A hostname is only asked about when it contains a hyphen, a dot or a digit.
  #
  # The word boundary moved which English words collide; it did not close the
  # class. Measured against the real committed files, 13 of 27 realistic
  # hostnames still red a clean cassette -- `main`, `build`, `model`, `tool`,
  # `file`, `user`, `path`, `name`, `type`, `true`, `stop`, `call`, `read`,
  # `gguf`: `build` from the modelfile's "To build a new Modelfile", `main` from
  # the HuggingFace `blob/main/LICENSE` link. `main` and `build` are ordinary CI
  # hostnames, and a guard that reds a clean tree on a machine called `build` is
  # a guard somebody deletes.
  #
  # Every one of those collisions is pure lowercase letters, and every realistic
  # hostname tried (`rainbow-dev`, `build-runner-07`, `mac-mini.local`) carries a
  # non-letter. That asymmetry is the cheap close. It costs the single-label
  # all-letter hostname, which is exactly the set that cannot be told from an
  # English word anyway.
  HOSTNAME_MUST_CONTAIN = /[-.\d]/

  # One thing that must not be in a committed cassette, and exactly where it is.
  # `#to_s` is what an rspec failure prints, so it has to name the shape and the
  # offset by itself -- nobody re-reads 58 KB of YAML by eye, which is this
  # object's own premise.
  Finding = Data.define(:cassette, :location, :shape, :offset, :excerpt) do
    def to_s = "#{cassette}: #{location} matched #{shape} at byte #{offset} -- #{excerpt}"
  end

  # Every local blob path replaced by {BLOB_PLACEHOLDER}. A regexp rather than
  # VCR's `filter_sensitive_data`, which substitutes ONE literal string per
  # declaration: the path differs per box and may appear more than once in a
  # single body.
  def self.redact(text)
    text.is_a?(String) ? text.gsub(BLOB_PATH, BLOB_PLACEHOLDER) : text
  end

  def self.findings_in(paths) = paths.flat_map { |path| findings(path) }

  # EVERY String in the parsed document is checked against the content shapes,
  # and header NAMES additionally against the credential shapes.
  #
  # An earlier version walked only `body.string` and `uri`, which was a coverage
  # REGRESSION against the whole-file grep it replaced: header VALUES went
  # entirely unscanned. Planted and confirmed unseen at the time --
  # `X-Forwarded-For: 192.168.1.44`, a hostname in a `User-Agent`, a
  # `Referer: file:///home/dana/models`, a blob path in a response `Location`, a
  # MAC in an `X-Device`, a path in the HTTP status MESSAGE, and anything outside
  # `http_interactions` at all. Walking the document reaches all of them, and it
  # cannot go stale when VCR's serialisation grows a field.
  #
  # It is a walk over the PARSED document rather than a grep of the file text on
  # purpose: YAML folds a long scalar across lines, so a raw grep can miss a path
  # that happens to straddle a wrap point -- and the committed `/api/show` body
  # is 55 KB of folded scalar.
  def self.findings(path)
    walk(File.basename(path), YAML.safe_load_file(path), "")
  end

  def self.walk(cassette, node, location)
    case node
    when Hash then hash_findings(cassette, node, location)
    when Array then node.each_with_index.flat_map { |item, index| walk(cassette, item, "#{location}[#{index}]") }
    when String then content_findings(cassette, node, location)
    else []
    end
  end
  private_class_method :walk

  # A key is tested as a credential HEADER only inside a `headers` hash. Testing
  # every key everywhere would be the S2 mistake again from the other direction.
  def self.hash_findings(cassette, hash, location)
    headers = location.end_with?("headers")
    hash.flat_map do |key, value|
      here = location.empty? ? key.to_s : "#{location}.#{key}"
      (headers ? header_name_findings(cassette, key, here) : []) + walk(cassette, value, here)
    end
  end
  private_class_method :hash_findings

  # The NAME is reported, never the value -- the value is the credential.
  def self.header_name_findings(cassette, name, location)
    return [] unless name.to_s.match?(CREDENTIAL_HEADER)

    [Finding.new(cassette:, location:, shape: "credential header", offset: 0, excerpt: name.to_s)]
  end
  private_class_method :header_name_findings

  def self.content_findings(cassette, text, location)
    return [] unless text.is_a?(String)

    shapes.filter_map do |shape, pattern|
      match = pattern.match(text)
      match && Finding.new(cassette:, location:, shape:, offset: match.begin(0), excerpt: excerpt_of(shape, match))
    end
  end
  private_class_method :content_findings

  def self.excerpt_of(shape, match)
    SECRET_SHAPES.include?(shape) ? "<#{match[0].length} redacted characters>" : match[0][0, 60]
  end
  private_class_method :excerpt_of

  # The generic shapes, plus this box's own home and hostname when they are long
  # enough to mean anything. Rebuilt per call rather than memoized: `Dir.home`
  # follows `HOME`, and a spec that moves it is entitled to be measured under it.
  #
  # The trailing `\b` on the home arm is what keeps `/home/tara` from claiming
  # `/home/tarantula` while still matching `/home/tara/.ollama`; there is no
  # LEADING one because the escaped path starts with `/`, and `\b/` would demand
  # a word character before it (so `FROM /home/tara` would not match at all).
  def self.shapes
    CONTENT_SHAPES.merge(home_shape).merge(hostname_shape)
  end

  def self.home_shape
    home = Dir.home
    return {} unless home.to_s.length >= MIN_LOCAL_TOKEN

    { "this box's home directory" => /#{Regexp.escape(home)}\b/ }
  end
  private_class_method :home_shape

  def self.hostname_shape
    host = Socket.gethostname.to_s
    return {} unless askable_hostname?(host)

    { "this box's hostname" => /\b#{Regexp.escape(host)}\b/ }
  end
  private_class_method :hostname_shape

  def self.askable_hostname?(host)
    host.length >= MIN_LOCAL_HOSTNAME &&
      host.match?(HOSTNAME_MUST_CONTAIN) &&
      !IGNORED_HOSTNAMES.include?(host.downcase)
  end
  private_class_method :askable_hostname?

  # The request half of VCR's `Response#update_content_length_header`, which VCR
  # ships on Response and NOT on Request -- the shared `Normalizers::Header#edit_header`
  # both would delegate to is PRIVATE, so this is spelled out rather than reached
  # with `send`. Same contract as VCR's: rewrite the header only when it is
  # already present, never add one, and match the name case-insensitively the way
  # `header_key` does.
  #
  # Latent today -- a blob path has never appeared in a REQUEST body -- but the
  # `before_record` hook that calls this is repo-wide now, so the asymmetry would
  # have been a stale `Content-Length` waiting for the first endpoint that posts
  # a path.
  def self.correct_content_length(headers, body)
    key = headers.to_h.keys.find { |name| name.to_s.casecmp?("content-length") }
    headers[key] = [body.to_s.bytesize.to_s] unless key.nil?
  end
end
