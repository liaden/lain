# frozen_string_literal: true

require "faraday"
require "ipaddr"
require "uri"

module Lain
  module Tools
    # Tier 1 (structured): fetches one URL and returns its body text. There is
    # no command string here for the model to control, so it sits at the lowest
    # tier -- but a network egress tool needs bounds a filesystem read does not,
    # and those bounds are STRUCTURAL, not an approval prompt (see the plan's
    # "Web-tool safety"): the body is STREAMED and the read is aborted once it
    # exceeds an egress byte-cap (a lying or absent Content-Length cannot defeat
    # it), redirects are capped, only http/https egress is allowed, NO auth
    # headers are ever sent, non-routable destinations are refused
    # unconditionally ({NonRoutable}), and an optional domain allowlist narrows
    # further -- the last two re-checked on every hop.
    # {#requires_approval?} stays false -- a subagent that owns this
    # tool gets no Gate, so a `true` here would be a no-op, and the real safety
    # is the structure, not a gate.
    #
    # Every failure -- a non-2xx status, too many redirects, a disallowed host
    # or scheme, a malformed redirect Location, a raising client -- is reported
    # as an error {Tool::Result}, never a raise: the loop must continue and the
    # model deserves an answer it can act on. The fetched page is returned as
    # content; it is NEVER written to stdout.
    class WebFetch < Tool
      # 5 MiB is a generous ceiling on a single egress: enough for any real
      # article, small enough to bound a runaway or hostile response.
      DEFAULT_BYTE_CAP = 5 * 1024 * 1024
      # Five hops covers legitimate canonicalization (http->https, trailing
      # slash, apex->www) without letting a redirect loop run unbounded.
      DEFAULT_REDIRECT_CAP = 5
      # Egress is confined to the web: a redirect to file://, gopher://, or a
      # data: URI is refused before the connection is ever asked to fetch it.
      ALLOWED_SCHEMES = %w[http https].freeze
      # The statuses whose BODY is the answer. Named because {ByteCap} needs the
      # same question answered mid-stream, and two spellings of "is this a
      # response we would return?" is one too many.
      SUCCESSFUL = (200..299)
      USER_AGENT = "lain-web-fetch/1"

      # The wire shape: one required URL. Shape only -- Tool::Input never
      # validates safety (see the comment atop tool/input.rb); the scheme guard,
      # allowlist, and caps below are the real bounds, and they live on the tool.
      class Input < Tool::Input
        field :url, :string, description: "Absolute http(s) URL to fetch.", required: true
      end

      input_model Input

      # The egress floor: the destinations a fetch tool has no business
      # reaching, refused as a property of the class. Deliberately NOT a
      # constructor argument -- the optional allowlist below is what a project
      # narrows with, and a second injectable seam here would be one more guard
      # that a construction site can be written without. This one cannot be.
      #
      # Link-local is the range that matters: 169.254.169.254 is where the major
      # clouds serve instance metadata, credentials included. Loopback and the
      # private ranges reach whatever else happens to be listening around the
      # agent -- measured, against a live listener on 127.0.0.1.
      #
      # Three grounds, and they make different kinds of claim: an address inside
      # a blocked range, a name reserved to a local network, and a host that is
      # address-shaped but will not canonicalise -- the last a disagreement
      # between this parse and the resolver's, not a statement about routing.
      # What they share is "not a destination on the public web", which is the
      # question this module actually answers.
      #
      # The check is LEXICAL, on the host as written, and that is rung one of
      # two. It stops http://169.254.169.254/ and it does NOT stop a public name
      # whose A record points there. Closing that needs resolution before the
      # request AND connecting to the address that was resolved -- resolving
      # alone reopens the hole as a rebind between the check and the connection
      # -- so it is a change in what this class does, not a widening of what it
      # already does.
      module NonRoutable
        # Each range carries the name its refusal quotes. "Not on the allowlist"
        # and "in a blocked range" send a reader to two different places, and
        # only one of them is configuration they can change. Order decides which
        # name a nested entry is refused under, so the specific ones come first.
        RANGES = { "127.0.0.0/8" => "loopback",
                   "::1" => "loopback",
                   "169.254.0.0/16" => "link-local",
                   "fe80::/10" => "link-local",
                   "10.0.0.0/8" => "private",
                   "172.16.0.0/12" => "private",
                   "192.168.0.0/16" => "private",
                   "fc00::/7" => "unique-local",
                   "0.0.0.0/8" => "unspecified",
                   "::" => "unspecified",
                   # Two more instance-metadata services, neither of which is in
                   # a range the previous rows cover: Alibaba Cloud serves
                   # credentials from 100.100.100.200 inside carrier-grade NAT,
                   # and Oracle Cloud Classic from 192.0.0.192 inside the IETF
                   # protocol block.
                   "100.64.0.0/10" => "carrier-grade NAT",
                   "192.0.0.0/24" => "IETF protocol assignment",
                   # Not a destination the open web serves: a multicast group
                   # and the broadcast address are not hosts at all, and
                   # 198.18.0.0/15 is set aside for benchmark rigs.
                   "224.0.0.0/4" => "multicast",
                   "255.255.255.255" => "broadcast",
                   "198.18.0.0/15" => "benchmarking",
                   # Two different things. Four are IPv6 transition prefixes,
                   # each of which embeds a v4 address -- measured, all four
                   # carry 169.254.169.254 -- so each is one more spelling of a
                   # destination the rows above already refuse, and 64:ff9b::/96
                   # is the NAT64 well-known prefix, which on a NAT64 network
                   # really does reach the metadata service. fec0::/10 embeds
                   # nothing: it is deprecated site-local unicast, the v6
                   # counterpart of the private rows. The four go whole rather
                   # than only their blocked embeddings, because all four are
                   # deprecated or resolver-generated and a model writing one as
                   # a literal is not making an ordinary fetch.
                   "::/96" => "IPv4-compatible IPv6",
                   "::ffff:0:0:0/96" => "IPv4-translated",
                   "64:ff9b::/96" => "NAT64",
                   "fec0::/10" => "site-local",
                   "2002::/16" => "6to4" }.freeze

        # Parsed once, each carrying the exact clause its refusal uses. An entry
        # with no prefix length is a single address, and calling ::1 a "range"
        # would be a small lie in the one sentence explaining the refusal.
        SUBNETS = RANGES.map do |cidr, label|
          shape = cidr.include?("/") ? "is in the blocked #{label} range" : "is the blocked #{label} address"
          [IPAddr.new(cidr).freeze, "#{shape} #{cidr}"]
        end.freeze

        # getaddrinfo("") is 0.0.0.0, which on Linux is this machine: measured
        # against a live listener, a production-shaped tool asked for
        # `http://:PORT/` and got the body back. An absent host is not "no
        # destination" -- it is the same door 0.0.0.0 opens, spelled so that a
        # host comparison has nothing to compare.
        MISSING_HOST = "web_fetch: the url names no host, which resolves to this machine"

        # Names that resolve inside a network rather than on the web: RFC 6761
        # reserves `localhost`, RFC 6762 `.local`, and `.internal` is both the
        # cloud convention and a reserved TLD.
        NAMES = %w[localhost internal local].freeze

        # A host whose every dot-separated part is numeric is what the C
        # resolver hands to inet_aton, and inet_aton accepts spellings IPAddr
        # does not: measured through getaddrinfo, `2130706433`, `0177.0.0.1` and
        # `127.1` are all 127.0.0.1, while IPAddr raises on all three. Where the
        # resolver and the parse disagree it is the parse that is wrong, so an
        # address-shaped host that will not canonicalise is refused rather than
        # passed.
        ADDRESS_SHAPED = /\A(0[xX]\h+|\d+)(\.(0[xX]\h+|\d+))*\z/

        class << self
          # nil when the host is one the open web can legitimately serve.
          #
          # One trailing dot is DNS root-anchoring -- the same name, written
          # absolutely -- so it comes off. TWO is not a hostname at all: the
          # second dot opens an empty label, which no resolver accepts. It is
          # left alone rather than stripped, and that looks like a hole and is
          # not: measured, `localhost..` and `127.0.0.1..` raise
          # Socket::ResolutionError and a real fetch reaches nothing, so a
          # double dot is a dead end rather than a door.
          def problem(host)
            name = host.to_s.downcase.delete_suffix(".")
            return MISSING_HOST if name.empty?

            address = address_of(name)
            return blocked_range(host, address) if address
            return ambiguous(host) if ADDRESS_SHAPED.match?(name)

            blocked_name(host, name)
          end

          private

          # An IPv4-mapped literal is the same destination written so that a v4
          # comparison never sees it, so it is narrowed before it is matched.
          def address_of(name)
            address = IPAddr.new(name)
            address.ipv4_mapped? ? address.native : address
          rescue IPAddr::Error
            nil
          end

          def blocked_range(host, address)
            _, clause = SUBNETS.find { |subnet, _| subnet.include?(address) }
            "web_fetch: host #{host.inspect} #{clause}" if clause
          end

          def blocked_name(host, name)
            reserved = NAMES.find { |word| name == word || name.end_with?(".#{word}") }
            "web_fetch: host #{host.inspect} is a blocked internal name (#{reserved})" if reserved
          end

          def ambiguous(host)
            "web_fetch: host #{host.inspect} is address-shaped but not a canonical address"
          end
        end
      end

      # Turning fetched bytes into a String {Lain::Canonical} accepts. A socket
      # hands a body back ASCII-8BIT and Canonical raises on any byte >= 0x80, so
      # something must decode -- and it is this tool, because this tool is what
      # knows it asked for a web page. Canonical stays strict: deterministic
      # bytes are its whole job.
      #
      # The ladder is mempalace's `decode_robust` (format_miner.py:197) with one
      # rung added in front and one rung fenced. In front: the charset the
      # response NAMED, when it named one and the bytes honour it. Fenced: the
      # CP1252 rung, which reinterprets the WHOLE body and so must not fire on a
      # body that is UTF-8 with damage in it. Then UTF-8, then CP1252, then a
      # scrub that cannot fail. It NEVER raises -- which is exactly why
      # {ContentType#textual?} has to decide that this is text at all before
      # anyone asks how to decode it.
      module Text
        # 0xC0 and up leads a multi-byte UTF-8 sequence; four bytes is the
        # longest one, so an unfinished sequence starts in the last three.
        LEAD_BYTE = 0xC0
        LONGEST_SEQUENCE = 4
        # `Encoding.find` also answers to four names that are not charsets at
        # all: they resolve to whatever THIS PROCESS is configured for. A remote
        # header must never be able to make the tool's output depend on the box
        # instead of on the bytes -- deterministic bytes are the premise both
        # turn hashing and prompt-cache stability rest on.
        PROCESS_ALIASES = %w[locale external internal filesystem].freeze

        class << self
          def decode(bytes, charset = nil)
            declared(bytes, charset) || robust(bytes, charset)
          end

          # How many bytes at the end of +buffer+ open a UTF-8 sequence it never
          # finishes; 0 when it ends on a whole character.
          def partial_tail(buffer)
            tail = trailing_bytes(buffer)
            lead = tail.rindex { |byte| byte >= LEAD_BYTE }
            return 0 if lead.nil?

            present = tail.size - lead
            present < sequence_length(tail[lead]) ? present : 0
          end

          private

          def trailing_bytes(buffer)
            window = [buffer.bytesize, LONGEST_SEQUENCE - 1].min
            buffer.byteslice(buffer.bytesize - window, window).bytes
          end

          def declared(bytes, charset)
            encoding = resolve(charset)
            candidate = bytes.dup.force_encoding(encoding) if encoding
            candidate.encode(Encoding::UTF_8) if candidate&.valid_encoding?
          rescue EncodingError
            nil
          end

          # nil for anything that is not a charset a remote party may name: an
          # absent or empty value, a process alias (see PROCESS_ALIASES), or a
          # name Ruby does not know. The ladder below handles all of them.
          def resolve(charset)
            name = charset.to_s.downcase
            return nil if name.empty? || PROCESS_ALIASES.include?(name)

            Encoding.find(name)
          rescue ArgumentError
            nil
          end

          # The CP1252 rung reinterprets EVERY byte, so it is right only when
          # the body really is legacy single-byte text. A UTF-8 page carrying
          # one mangled byte -- a CMS splice, an upstream cut -- would otherwise
          # come back as "cafÃ© ' quote": believable mojibake, the same failure
          # class the cap's rounding exists to prevent, through another door.
          # So: if the server said UTF-8, or the bytes still hold a valid
          # multi-byte character after the damage is dropped, scrub instead.
          def robust(bytes, charset)
            utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
            return utf8 if utf8.valid_encoding?
            return utf8.scrub if resolve(charset) == Encoding::UTF_8 || damaged_utf8?(utf8)

            cp1252(bytes) || utf8.scrub
          end

          # Bytes that are genuinely CP1252 do not spell valid multi-byte UTF-8
          # by accident, so a surviving multi-byte character says "this was
          # UTF-8, with damage" rather than "this was CP1252".
          def damaged_utf8?(utf8)
            surviving = utf8.scrub("")
            surviving.bytesize > surviving.length
          end

          # Windows-1252 leaves five bytes undefined, so this rung can still
          # refuse -- and then the scrub below it is what cannot.
          def cp1252(bytes)
            bytes.dup.force_encoding(Encoding::WINDOWS_1252).encode(Encoding::UTF_8)
          rescue EncodingError
            nil
          end

          def sequence_length(lead)
            case lead
            when 0xC0..0xDF then 2
            when 0xE0..0xEF then 3
            when 0xF0..0xF7 then 4
            else 1
            end
          end
        end
      end

      # The response's Content-Type, reduced to the two questions the tool asks
      # of it: is this text at all, and in what encoding.
      class ContentType
        # The structured text types the web serves under `application/*`. The
        # `+json` / `+xml` suffixes cover the long tail (`application/ld+json`).
        TEXTUAL_SUBTYPES = %w[json xml javascript ecmascript x-ndjson yaml x-yaml].freeze
        # C0 control bytes that are not whitespace. Text hardly ever carries
        # one; binary formats are full of them.
        CONTROL_BYTES = /[\x00-\x08\x0b\x0e-\x1f]/n
        # One control byte in twenty is already far more than prose produces,
        # and a NUL alone settles it.
        CONTROL_DENSITY = 0.05

        # Header lookup is spelled both ways because a streaming env hands back
        # whatever Hash the adapter built, not always Faraday's case-insensitive
        # one (the same reason `location` is read twice below).
        def self.of(headers)
          new(headers["content-type"] || headers["Content-Type"])
        end

        attr_reader :charset

        def initialize(value)
          @value = value.to_s
          # RFC 9110 forbids whitespace around a parameter's `=`, but a lenient
          # server sends `charset = utf-8` and silently losing the value it DID
          # give us is worse than accepting the sloppiness.
          media, *parameters = @value.split(";").map { |part| part.strip.downcase.gsub(/\s*=\s*/, "=") }
          @media = media.to_s
          @charset = parameters.find { |parameter| parameter.start_with?("charset=") }
                               &.delete_prefix("charset=")&.delete('"')
        end

        # A body is text when the server SAYS so, and when it says nothing the
        # bytes are asked instead. "Absent means text" alone would reopen the
        # door this check exists to close: the ladder never fails, so a PNG
        # served bare would come back as `‰PNG` -- valid UTF-8, canonicalising
        # clean, handed to the model as a page. A sample of the body is the only
        # evidence there is in that case, and NUL bytes or a crowd of C0
        # controls are what binary looks like.
        def textual?(sample = "")
          return @media.start_with?("text/") || structured_text? unless @media.empty?

          !binary?(sample)
        end

        # How a refusal names this body. A server that sent nothing has no type
        # to quote, so the refusal names what was sniffed instead.
        def description
          @value.empty? ? "an unlabelled binary body" : "non-text content type #{@value.inspect}"
        end

        def to_s = @value

        private

        def structured_text?
          type, _, subtype = @media.partition("/")
          type == "application" && (TEXTUAL_SUBTYPES.include?(subtype) || subtype.end_with?("+json", "+xml"))
        end

        # `.b` because a chunk may arrive tagged UTF-8 with invalid bytes in it,
        # and `scan` raises on those rather than matching them.
        def binary?(sample)
          bytes = sample.b
          return false if bytes.empty?

          bytes.include?("\x00") || (bytes.scan(CONTROL_BYTES).size.to_f / bytes.bytesize) > CONTROL_DENSITY
        end
      end

      # A streaming sink for Faraday's `on_data`: it accumulates body bytes and
      # ABORTS the read (by raising, the only way Faraday stops a stream) the
      # moment the total would exceed the cap. So the cap bounds the actual read,
      # not just a post-hoc truncation of an already-buffered body.
      class ByteCap
        class Reached < StandardError
        end

        # Aborts the read the same way {Reached} does, but because the body is
        # not text at all. Its message is how the refusal names the body.
        class Refused < StandardError
        end

        attr_reader :status, :headers

        def initialize(cap)
          @cap = cap
          # BINARY rather than the UTF-8 a `+""` would give here -- see #accept.
          @bytes = "".b
          @truncated = false
          @status = nil
          @headers = {}
          @screened = false
        end

        # Faraday 2 hands `(chunk, received_bytes, env)`; earlier arities pass
        # fewer, so the tail is defaulted.
        def call(chunk, _received = nil, env = nil)
          capture(env)
          screen(chunk)
          accept(chunk, @cap - @bytes.bytesize)
        end

        def truncated? = @truncated

        # A fresh copy so the accumulated buffer cannot be mutated after the fact.
        def bytes = @bytes.dup

        def bytesize = @bytes.bytesize

        private

        # The status and headers of the response being streamed. Faraday saves
        # both BEFORE the first chunk (net_http's `save_http_response` precedes
        # `read_body`), so they are all an aborted read will ever have -- and
        # they are what lets a capped binary body still be refused by name.
        def capture(env)
          @status = env.status if env.respond_to?(:status)
          @headers = env.response_headers if env.respond_to?(:response_headers) && env.response_headers
        end

        # Whether this is text at all is decided ONCE, on the first chunk, and a
        # non-text body aborts the read there. The headers are already in hand
        # by then, so streaming megabytes of a PNG in order to discard them
        # would be this class's own structural bound leaking. Only a body that
        # would actually be RETURNED is worth refusing: a redirect must never be
        # blocked by whatever type its empty body claims, and a non-2xx is
        # already answered by its status.
        def screen(chunk)
          return if @screened

          @screened = true
          type = ContentType.of(@headers)
          raise Refused, type.description if returnable? && !type.textual?(chunk)
        end

        def returnable? = @status.nil? || SUCCESSFUL.cover?(@status)

        # The buffer is BINARY and every chunk is coerced to it. A buffer that
        # took its encoding from whichever chunk first carried a high byte raises
        # Encoding::CompatibilityError as soon as a later chunk disagrees; the
        # encoding question is settled once, at the end, by {Text.decode}.
        def accept(chunk, room)
          if chunk.bytesize <= room
            @bytes << chunk.b
          else
            @bytes << chunk.byteslice(0, room).b
            round_down_to_character
            @truncated = true
            raise Reached
          end
        end

        # The cap lands on an arbitrary byte, so the buffer can end mid-character
        # -- and the ladder decodes a split character into BELIEVABLE mojibake
        # ("cafÃ") rather than a visible loss. Rounding down here, before the
        # read is aborted, is what makes the returned body <= the cap rather than
        # exactly it.
        def round_down_to_character
          partial = Text.partial_tail(@bytes)
          @bytes = @bytes.byteslice(0, @bytes.bytesize - partial) if partial.positive?
        end
      end

      # The HTTP client is injected (default a real, credential-free Faraday
      # connection) so specs substitute a stub and never touch the network. The
      # caps and allowlist are constructor config, not model input: the model
      # must not be able to widen its own bounds.
      def initialize(connection: nil, byte_cap: DEFAULT_BYTE_CAP, redirect_cap: DEFAULT_REDIRECT_CAP, allowlist: nil)
        super()
        @connection = connection || default_connection
        @byte_cap = byte_cap
        @redirect_cap = redirect_cap
        @allowlist = allowlist
      end

      def name = "web_fetch"

      def description
        "Fetches a single http(s) URL and returns its body text. The response " \
          "is streamed and capped in size, redirects are bounded, and a non-2xx " \
          "status or a network error is returned as an error result."
      end

      # A bare Faraday connection carrying only a User-Agent -- and, pointedly,
      # NO Authorization, Cookie, or other credential header, and no redirect
      # middleware (redirects are followed here, so each hop can be re-checked).
      # Exposed so the no-auth invariant is directly assertable.
      def default_connection
        Faraday.new(headers: { "User-Agent" => USER_AGENT })
      end

      protected

      def perform(input, _invocation)
        follow(input.url, @redirect_cap)
      rescue Faraday::Error => e
        Tool::Result.error("web_fetch failed for #{input.url}: #{e.message}")
      end

      private

      # One hop. The egress guard (scheme + allowlist) runs BEFORE the fetch, so
      # a disallowed host or scheme is never contacted -- and because a redirect
      # recurses through here, that guard is re-applied to every hop.
      def follow(url, budget)
        problem = egress_problem(url)
        return Tool::Result.error(problem) if problem

        status, headers, cap = fetch(url)
        return redirect(url, headers, budget) if redirect?(status, headers)
        return Tool::Result.error("web_fetch: #{status} for #{url}") unless success?(status)

        Tool::Result.ok(rendered(cap, ContentType.of(headers).charset))
      rescue ByteCap::Refused => e
        Tool::Result.error("web_fetch: refusing #{e.message} for #{url}")
      end

      def redirect(from, headers, budget)
        if budget.zero?
          return Tool::Result.error("web_fetch: too many redirects (cap #{@redirect_cap}) starting at #{from}")
        end

        follow(URI.join(from, location_of(headers)).to_s, budget - 1)
      rescue URI::InvalidURIError => e
        Tool::Result.error("web_fetch: malformed redirect Location #{location_of(headers).inspect}: #{e.message}")
      end

      # Streams the body through the byte cap. On a normal completion the
      # response carries status and headers; on an aborted read (cap reached)
      # there is no response at all, so both come from what the cap captured off
      # the streaming env -- which is why a capped binary body is still refused
      # by name rather than decoded.
      def fetch(url)
        cap = ByteCap.new(@byte_cap)
        response = @connection.get(url) { |req| req.options.on_data = stream_into(cap) }
        [response.status, response.headers || {}, cap]
      rescue ByteCap::Reached
        [cap.status || 200, cap.headers, cap]
      end

      def stream_into(cap)
        proc { |chunk, received, env| cap.call(chunk, received, env) }
      end

      # The label reports the bytes actually RETURNED, not the cap: rounding
      # down to a character boundary means the body is <= the cap, and telling
      # the model "truncated at 4 bytes" beside a three-byte body is a small lie
      # in the one sentence explaining why the page is short.
      def rendered(cap, charset)
        text = Text.decode(cap.bytes, charset)
        return text unless cap.truncated?

        label = "[web_fetch: truncated at #{cap.bytesize} bytes]"
        text.empty? ? label : "#{text}\n\n#{label}"
      end

      def redirect?(status, headers)
        (300..399).cover?(status) && !location_of(headers).nil?
      end

      def location_of(headers)
        headers["location"] || headers["Location"]
      end

      def success?(status)
        SUCCESSFUL.cover?(status)
      end

      # The combined egress guard: an unsupported scheme, a non-routable
      # destination, or a host off the allowlist is a named refusal; nil means
      # "go ahead". A URL we cannot even parse is refused rather than handed to
      # the connection. The floor is asked BEFORE the allowlist because it is
      # the refusal no configuration can lift, and answering it with the
      # allowlist's wording would send a reader to a file that cannot help them.
      #
      # Two spellings of the host one line apart, on purpose. `hostname` is the
      # host as a NAME -- an IPv6 literal without the brackets its URL form
      # carries -- which is the thing the floor asks about; the allowlist
      # compares domain suffixes and has always read `host`. IPAddr turns out to
      # strip the brackets itself, so the floor would survive `host` too: it is
      # asking the right accessor, not leaning on that.
      def egress_problem(url)
        uri = URI.parse(url)
        return "web_fetch: unsupported scheme #{uri.scheme.inspect} (only http/https)" unless allowed_scheme?(uri)

        NonRoutable.problem(uri.hostname) || allowlist_problem(uri.host)
      rescue URI::InvalidURIError => e
        "web_fetch: invalid url #{url.inspect}: #{e.message}"
      end

      def allowed_scheme?(uri)
        ALLOWED_SCHEMES.include?(uri.scheme)
      end

      # nil allowlist means "no restriction". A configured allowlist matches the
      # host exactly or as a parent domain (example.com allows www.example.com).
      def allowlist_problem(host)
        return nil if @allowlist.nil?
        return nil if host && @allowlist.any? { |domain| host == domain || host.end_with?(".#{domain}") }

        "web_fetch: host #{host.inspect} is not on the allowlist"
      end
    end
  end
end
