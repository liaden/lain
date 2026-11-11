# frozen_string_literal: true

require "openssl"
require "zlib"

RSpec.describe Lain::Sensitivity::Regions do
  def detect(content, **options) = described_class.detect(content, **options)

  def digests(content) = detect(content).map(&:digest)

  # Long enough and random enough that no threshold under discussion misses it,
  # so an example about POSITION never fails for a reason about ENTROPY.
  let(:secret) { "kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3" }

  # `yaml assignment` is LINE-ANCHORED, so a `Note:` sitting mid-paragraph is not
  # reached by the shape that floods and this fixture would prove nothing. Both
  # colon lines start at column 0 deliberately.
  let(:prose) do
    <<~PROSE
      # Lain

      Lain is an agent harness built as a study bench. The agent is the vehicle
      and the bench is the deliverable.

      Note: this line begins at column 0 so the flooding shape actually reaches it.
      Warning: so does this one, and neither may report a region.

      Run the suite with rake, and read the output before believing it.
    PROSE
  end

  describe ".detect" do
    context "when a dotenv line assigns an API key" do
      let(:content) do
        <<~ENV
          # configuration for the local run
          Run this before anything else.
          API_KEY=#{secret}
          The line above is the only interesting one.
        ENV
      end

      it "reports exactly one region" do
        expect(detect(content).size).to eq(1)
      end

      # Both readings of the AC at once. The region sits inside the assignment,
      # and it excludes the NAME -- masking renders an unreleased region as
      # `<redacted:N>`, and a region covering `API_KEY=...` would erase the key
      # name that the "structure survives" contract promises to keep.
      it "covers the assignment's value and not its name" do
        region = detect(content).first

        expect(content.byteslice(region.start, region.length)).to eq(secret)
        expect(content.byteslice(region.start, region.length)).not_to include("API_KEY")
        expect(content.lines.find { |line| line.include?(secret) }).to include("API_KEY=")
      end

      # `API_KEY=` is both a dotenv assignment and the write side's name-gated
      # `credential assignment`. The table's own order decides, so the region is
      # named by the shape that says more.
      it "names the shape that matched, preferring the more specific one" do
        expect(detect(content).first.reason).to eq("credential assignment")
      end

      it "attributes it to the pattern detector" do
        expect(detect(content).first).to have_attributes(detector: :pattern, entropy?: false)
      end

      it "refuses a detector it does not know" do
        expect { described_class::Region.new(start: 0, bytes: "x", reason: "y", detector: :guess) }
          .to raise_error(ArgumentError, /unknown detector/)
      end
    end

    context "when a comment line is inserted above a region" do
      let(:before) { "API_KEY=#{secret}\ntrailing line\n" }
      let(:after) { "# a note added later\nAPI_KEY=#{secret}\ntrailing line\n" }

      # The whole point of the card: identity is the bytes, never the offset.
      it "leaves the region's digest unchanged" do
        expect(digests(after)).to eq(digests(before))
      end

      it "moves the region's offset" do
        expect(detect(after).first.start).to be > detect(before).first.start
      end
    end

    context "when a second key is added elsewhere in the file" do
      let(:other) { "Zx4Wn7Qv2Rt9Yb5Ke1Mh8Jd3Fg6Ls0Pc4Xa7Nu2Iy5Or8Tw1" }
      let(:before) { "first line\nAPI_KEY=#{secret}\nlast line\n" }
      let(:after) { "first line\nAPI_KEY=#{secret}\nOTHER_KEY=#{other}\nlast line\n" }

      it "gains exactly one digest" do
        expect(digests(after).size).to eq(digests(before).size + 1)
      end

      it "leaves the existing digests unchanged" do
        expect(digests(after)).to include(*digests(before))
      end
    end

    context "when a high-entropy token carries no recognizable prefix" do
      # A bare token on its own line: no assignment, no issuer prefix, nothing
      # for the pattern set to see.
      let(:content) { "the value is\n#{secret}\nand that was it\n" }

      it "reports it" do
        expect(detect(content).size).to eq(1)
        expect(content.byteslice(*detect(content).first.then { [_1.start, _1.length] })).to eq(secret)
      end

      it "names entropy as the reason" do
        expect(detect(content).first.reason).to eq("high-entropy token")
      end

      # Triage and a match must stay tellable apart without string-comparing a
      # reason: the release prompt says different things about each, and the
      # Journal records which detector spoke.
      it "attributes it to the entropy detector" do
        expect(detect(content).first).to have_attributes(detector: :entropy, entropy?: true)
      end
    end

    context "when a token is slash-joined words" do
      ["Cargo/Dioxus/clippy/deny/pre-commit",
       "XDG_CONFIG_HOME/lain/config",
       "github.com/lmcnulty/gender-voice-visualization_corpus",
       "/usr/lib/x86_64-linux-gnu/qt6/plugins/wayland-graphics-integration-client"].each do |text|
        it "reports nothing for #{text}" do
          expect(detect("see #{text} here\n")).to be_empty
        end
      end

      it "still reports a secret whose segments are not words" do
        regions = detect("the value is wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n")

        expect(regions.map { [_1.bytes, _1.reason] })
          .to eq([["wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "high-entropy token"]])
      end

      it "keeps the whole candidate flagged when 1 segment is mixed case" do
        regions = detect("path config/prod/q8ZtLm2xR4vN7kPw9sYb\n")

        expect(regions.map { [_1.bytes, _1.reason] })
          .to eq([["config/prod/q8ZtLm2xR4vN7kPw9sYb", "high-entropy token"]])
      end

      # Lowercase hex and base36 are word-shaped character by character, so a
      # key sitting in a URL or path segment needs its own exclusion.
      {
        "a Datadog intake key" => ["https://http-intake.logs.datadoghq.com/v1/input/",
                                   "9f8e7d6c5b4a39281706f5e4d3c2b1a0"],
        "a webhook secret" => ["https://hooks.example.com/hooks/",
                               "3f5a9c2e1d7b4a6f8e0c2b5d7a9f1e3c5b7d9f2a4c6e8a0b2d4f6a8c0e2b4d6f"],
        "a token file under /var/lib" => ["cat /var/lib/app/tokens/", "3f5a9c2e1d7b4a6f8e0c2b5d7a9f1e3c5b7d9f2a"],
        "a Zapier catch hook" => ["https://hooks.zapier.com/hooks/catch/1234567/", "k3n9x2q7w5m1z8r4t6y0p2v5b7c9d1f3"]
      }.each do |label, (prefix, key)|
        it "still reports #{label} in a path segment" do
          expect(detect("#{prefix}#{key}\n").map(&:bytes)).to include(a_string_including(key))
        end
      end
    end

    context "when a token holds an alphabet literal" do
      it "reports nothing for the base64 alphabet" do
        expect(detect("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/\n")).to be_empty
      end

      it "reports nothing for a 16-character run that is most of the token" do
        expect(detect("x ABCDEFGHIJKLMNOPq7Zr9Lw2\n")).to be_empty
      end

      it "reports a 15-character run that is most of the token" do
        expect(detect("x ABCDEFGHIJKLMNOq7Zr9Lw2Xk\n").map(&:bytes)).to eq(["ABCDEFGHIJKLMNOq7Zr9Lw2Xk"])
      end

      it "reports a secret glued onto a run" do
        glued = "ABCDEFGHIJKLMNOPq7Zr9Lw2Xk4Vb8Nm3"

        expect(detect("x #{glued}\n").map(&:bytes)).to eq([glued])
      end
    end

    # Hex maxes out at 4.0 bits/char and so can never clear the base64 floor of
    # 4.2 -- it needs its own branch, and before these examples that branch had
    # negative controls only. Nothing made it fire in the affirmative, so both of
    # its constants could be moved out of reach with the suite still green.
    # Uppercase, because lowercase hex of a digest's width is read as a digest.
    context "when a bare hex token is long and unpredictable" do
      let(:hex_key) { "9F8E7D6C5B4A39281706F5E4D3C2B1A0" }

      it "reports a 32-character hex key" do
        expect(detect("the value is #{hex_key} and that was it\n").map(&:bytes)).to eq([hex_key])
      end

      it "names entropy as the reason" do
        expect(detect(hex_key).map(&:reason)).to eq(["high-entropy token"])
      end

      # The floor pinned from both sides: 20 bytes is reported, 19 is not. The
      # lengths are LITERAL and not derived from `Entropy::HEX_LENGTH` on purpose -- an
      # example that slices its fixture to the constant under test moves with it
      # and can never fail, which is how the first draft of this pair passed
      # against a floor of 10.
      it "reports a 20-byte hex token, which is the length floor" do
        at_floor = "9f8e7d6c5b4a39281706"

        expect(detect("value #{at_floor} end").map(&:bytes)).to eq([at_floor])
      end

      # Named for what it actually pins. A BARE 19-byte run is below `TOKEN`'s own
      # `{20,}` minimum, so it is never a candidate and `Entropy::HEX_LENGTH` never gets to
      # speak -- which is why no mutant of `Entropy::HEX_LENGTH` can fail THIS example.
      it "ignores a bare 19-byte run, which is below the token scanner's minimum" do
        below = "9f8e7d6c5b4a3928170"

        expect(detect("value #{below} end")).to be_empty
      end

      # `Entropy.high?` has TWO callers, and only the entropy scanner is
      # TOKEN-filtered. An assignment's VALUE reaches it through
      # `qualifies? -> secret_shaped?` with no length pre-filter at all, so
      # `Entropy::HEX_LENGTH` binds in BOTH directions on this path. Lowering it to 10
      # makes this line report a region; nothing else in the file covers that.
      it "ignores a short hex assignment value, which no token filter guards" do
        expect(detect("blob = 3f5a9c2e1d7b\n")).to be_empty
      end
    end

    context "when a line holds a digest or a secret beside one" do
      corpus = YAML.load_file(File.expand_path("../../fixtures/sensitivity/digest_corpus.yml", __dir__))

      corpus.each do |row|
        it "reports #{row.fetch("regions")} for #{row.fetch("label")}#{" (a known miss)" if row["known_miss"]}" do
          expect(detect(Array(row.fetch("line")).join).size).to eq(row.fetch("regions"))
        end
      end

      it "reports none across a digest list" do
        lines = ["b56e5bab6e1d0e3a1f0c4d2a9b8e7f6c5d4a3b2c1e0f9a8b7c6d5e4f3a7a1d43  downloads/ami.zip",
                 "{\"digest\":\"0a30b9c6b180dc54cd7b937fb534e1cfb45c88a1ffab0b461ad2e62089c8f108\"}",
                 "turn: blake3:519dec41a9ed05ce825112a2dd6969722af81c09b239272ff8b876cfb3474b81"]

        expect(detect(lines.join("\n"))).to be_empty
      end

      digest = "87a760f0e59750fc3c04a887a562c415784bdd55fd442b604230dea3587eb2ce"
      contexts = {
        "after a space" => ->(name) { "the #{name} #{digest}" },
        "after export" => ->(name) { "export #{name}=#{digest}" },
        "as an indented YAML key" => ->(name) { "  #{name}: #{digest}" },
        "as a JSON key" => ->(name) { "{\"#{name}\": \"#{digest}\"}" }
      }

      ordinary = %w[monkey turkey]
      keys = %w[DaemonKey commonKey saturKey]

      contexts.each do |where, line|
        ordinary.each do |word|
          it "reads #{word} #{where} as an ordinary word" do
            expect(detect(line.call(word))).to be_empty
          end
        end
      end

      contexts.except("after a space").each do |where, line|
        keys.each do |name|
          it "reads #{name} #{where} as a key" do
            expect(detect(line.call(name)).size).to eq(1)
          end
        end
      end

      %w[monkey turkey donkey jockey hockey whiskey lackey malarkey].each do |word|
        it "reads #{word} as an ordinary word, not a key" do
          expect(detect("#{word}: 87a760f0e59750fc3c04a887a562c415784bdd55fd442b604230dea3587eb2ce")).to be_empty
        end
      end

      it "reports one region for a keyed 64-hex secret" do
        expect(detect('api_key = "28e89f0b9fca089cc2c6396a4ccfa0e37f639d263349669a581a6936df935634"').size).to eq(1)
      end
    end

    context "when the content is ordinary prose" do
      it "reports nothing" do
        expect(detect(prose)).to be_empty
      end
    end

    # A public key is public by definition, and its base64 blob is exactly the
    # run the entropy detector exists to find: every real `.pub`, known_hosts
    # and authorized_keys file reported a region, so `read_file` parked on it
    # and automatic approval refused `cat id_ed25519.pub`. Real `ssh-keygen`
    # and OpenSSL output, fixed here so no spec depends on either binary.
    context "when the content is public-key material" do
      let(:ed25519) do
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGRIVMdBD52mo93GQUaBiP1vMNsCtBXvXV5RzHSnbH8E dev@example.com"
      end
      let(:ecdsa) do
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHaaO7lZ2p88MMLPMBsE7loQRZ2exV5P8jE/" \
          "bNKfHah1Wk5mx97onXKSHZX/5Q3ekqx+RKgmhzfVseDp/Pt9hbc= ci@example.com"
      end
      let(:rsa) do
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDi+iTijohI1wFF/u6XFNB68z9AuqsmxpLBAAtBh5jIb2ZrsjdemruStwW6sS" \
          "SreOd24pNu1eAQAtriwlPHxJQiUJU+OM5eb8XW+pXsKPRfLiydRp6wsji/Fe0/OlzDEM6Z5CVmhgHsUJENSKjGyGC73NE7FsrT" \
          "t8VfNcTkzHb18j/Lakb32GaKHtMW/e1MxoQcjXsU+q9eQN9XQohS3nnKHaUNXIpKrDJaF0xrJmCyrqMa14DmLZsl+41NgrFdZf" \
          "xnrSJWHa+HGZocqkjSkcNB5Xq3mdMLZQDTJjGfHnqbyLSrI+Z6quY8Q18WrssDy4JM6u3SDNm334bEJLKo7blR dev@example.com"
      end
      let(:pem_public) do
        "-----BEGIN PUBLIC KEY-----\n" \
          "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEEqLZqfP50K+z6ugZCcMvznsfNKm3\n" \
          "kGLxuY1KbqTsdEfeoCI93bNaaDVQwitfuWhftAwhK9qnoloVYfeVgSPu3g==\n" \
          "-----END PUBLIC KEY-----\n"
      end
      let(:pem_private) do
        "-----BEGIN PRIVATE KEY-----\n" \
          "MIIBVgIBADANBgkqhkiG9w0BAQEFAASCAUAwggE8AgEAAkEAqwertyuiop\n" \
          "asdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM1234567890abcdef\n" \
          "-----END PRIVATE KEY-----\n"
      end

      def masked?(content, text) = detect(content).any? { |region| region.bytes.include?(text) }

      def ssh_string(bytes) = [bytes.bytesize].pack("N") + bytes.b

      def ssh_line(type, *fields) = "#{type} #{[([type] + fields).map { ssh_string(_1) }.join].pack("m0")}"

      it "reports nothing for an OpenSSH public key line of each type" do
        expect([ed25519, ecdsa, rsa].map { |line| detect("#{line}\n") }).to all(be_empty)
      end

      it "reports nothing for an authorized_keys line with options, or a known_hosts line" do
        content = %(from="10.0.0.0/8",no-pty #{ed25519}\ngithub.com,140.82.112.3 #{rsa}\n)

        expect(detect(content)).to be_empty
      end

      it "reports nothing for a PEM public key block" do
        expect(detect(pem_public)).to be_empty
      end

      # A shape alone would unmask any token written after a key-type word. The
      # blob of a real key names its own type.
      it "still reports a token behind a key-type word whose blob does not name that type" do
        forged = "ssh-ed25519 AAAAkJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3 dev@example.com\n"

        expect(detect(forged)).not_to be_empty
      end

      it "still reports a secret sitting where a public key's comment goes" do
        content = "#{ed25519.delete_suffix(" dev@example.com")} sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE\n"

        expect(masked?(content, "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE")).to be(true)
      end

      it "still masks a private block that follows a public one" do
        content = "#{pem_public}#{pem_private}"

        expect(detect(content).size).to eq(1)
        expect(masked?(content, pem_private.chomp)).to be(true)
      end

      it "still masks a private block written inside public armour" do
        content = "-----BEGIN PUBLIC KEY-----\n#{pem_private}-----END PUBLIC KEY-----\n"

        expect(masked?(content, pem_private.lines[1].chomp)).to be(true)
      end

      it "still masks an OpenSSH private key" do
        key = "-----BEGIN OPENSSH PRIVATE KEY-----\n" \
              "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n" \
              "QyNTUxOQAAACBkSFTHQQ+dpqPdxkFGgYj9bzDbArQV711eUcx0p2x/BAAAAJiFPjsMhT47\n" \
              "-----END OPENSSH PRIVATE KEY-----\n"

        expect(masked?(key, key.chomp)).to be(true)
      end

      it "reports nothing for a PKCS#1 RSA PUBLIC KEY block" do
        block = "-----BEGIN RSA PUBLIC KEY-----\n" \
                "MIIBCgKCAQEAwz3qQmvsVVedOdJ21oVPsXTEVzKgoiCE2ab/Z4yhVcojPJ7gO38n\n" \
                "roJvGmZ8UJW5QinDVKdykgiZ5mzue4hncOAJ481PvTRRVSvKKk6ZAHlTBxKBZbvb\n" \
                "CHdEzfIQ0oFhtZ6rs+fjLy3l3UfnJkFNWaWkZoe+PWyhbOHbHa7cLMSRLl6lhZoL\n" \
                "sHCshaqJcVQt7GVSkD5OpPFfixStbCnRLj+tmGGLQ1p5ivb7Pcrqms2fAPHehxzH\n" \
                "4jtGmj5GMYgTKpVykUFSM77YDAKHe7xtlUPx/jufjIiNvK22nrad7LwH0/XAGC3m\n" \
                "omznL4EnSzz7vbhaE3iQwX4ElBCm5N+woQIDAQAB\n" \
                "-----END RSA PUBLIC KEY-----\n"

        expect(detect(block)).to be_empty
      end

      # No hardware token writes one here, so the security-key variants are
      # assembled in their wire format: the key, then the application string.
      it "reports nothing for a security-key line of either type" do
        ed = ssh_line("sk-ssh-ed25519@openssh.com", "\x11".b * 32, "ssh:")
        ec = ssh_line("sk-ecdsa-sha2-nistp256@openssh.com", "nistp256", "\x04".b + ("\x22".b * 64), "ssh:")

        expect([ed, ec].map { |line| detect("#{line} dev@example.com\n") }).to all(be_empty)
      end

      # The exemption is for a public key's exact wire format. Anything past the
      # fields a type defines -- a private seed, a payload, a glued token -- is
      # bytes the format does not account for, and is not public.
      describe "a blob that is not exactly a public key" do
        let(:aws_secret) { "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" }
        let(:ed25519_blob) { ed25519.split[1] }

        it "masks the private section's layout written behind the type word" do
          line = ssh_line("ssh-ed25519", Random.new(7).bytes(32), Random.new(8).bytes(64))

          expect(masked?("#{line} dev@example.com\n", line.split[1])).to be(true)
        end

        it "masks the type string followed by arbitrary bytes" do
          line = "ssh-ed25519 #{[ssh_string("ssh-ed25519") + "payload: #{aws_secret}"].pack("m0")}"

          expect(masked?("#{line}\n", line.split[1])).to be(true)
        end

        it "masks a secret glued onto a real unpadded blob" do
          expect(masked?("ssh-ed25519 #{ed25519_blob}#{aws_secret} dev@example.com\n", aws_secret)).to be(true)
          expect(masked?("ssh-ed25519 #{ed25519_blob}3f5a9c2e1d7b4a6f8e0c2b5d7a9f1e3c5b7d9f2a\n",
                         "3f5a9c2e1d7b4a6f8e0c2b5d7a9f1e3c5b7d9f2a")).to be(true)
        end

        it "grants no exemption to a type it does not parse" do
          fields = (0..3).map { |seed| Random.new(seed).bytes(20) }
          line = ssh_line("ssh-dss", *fields)

          expect(detect("#{line}\n")).not_to be_empty
        end
      end

      # Armour is a label anyone can write. A private body under a public label
      # is still a private body, and it is masked WHOLE: left to the entropy
      # detector line by line, a short last line would survive, which is the
      # gap the private block's own span closes.
      describe "a private body relabelled as public" do
        def relabel(pem, from, to) = pem.gsub(from, to)

        def whole_block?(pem) = detect(pem).map(&:bytes) == [pem.chomp]

        it "masks a PKCS#8 private body under PUBLIC KEY armour as one block" do
          pem = relabel(OpenSSL::PKey::RSA.generate(2048).private_to_pem, "PRIVATE KEY", "PUBLIC KEY")

          expect(whole_block?(pem)).to be(true)
        end

        it "masks a PKCS#1 private body under RSA PUBLIC KEY armour as one block" do
          pem = relabel(OpenSSL::PKey::RSA.generate(2048).to_pem, "RSA PRIVATE KEY", "RSA PUBLIC KEY")

          expect(whole_block?(pem)).to be(true)
        end

        it "masks armour whose body is not DER at all" do
          pem = "-----BEGIN PUBLIC KEY-----\nkJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3\nAbC=\n" \
                "-----END PUBLIC KEY-----\n"

          expect(whole_block?(pem)).to be(true)
        end
      end
    end

    # The gate, pinned from both sides. Without it the assignment shapes match
    # `^ident = value`, which IS Ruby assignment syntax, and every source file
    # the agent reads yields regions.
    context "when a common password shape carries a value no name arm reaches" do
      {
        "a double-quoted json key" => ['{"password": "hunter2xyz"}', "hunter2xyz"],
        "a single-quoted python key" => ["{'password': 'hunter2xyz'}", "hunter2xyz"],
        "a suffixed yaml key" => ["db_password: hunter2xyz", "hunter2xyz"],
        "url credentials" => ["postgres://app:hunter2xyz@db.local/app", "hunter2xyz"],
        "a mysql password flag" => ["mysql -u root -phunter2xyz", "hunter2xyz"],
        "a bearer header" => ["Authorization: Bearer abcdef0123456789abcd", "abcdef0123456789abcd"],
        "a short bearer token" => ["Authorization: Bearer hunter2xyz", "hunter2xyz"]
      }.each do |label, (line, value)|
        it "masks only the value of #{label}" do
          expect(detect(line).map(&:bytes)).to eq([value])
        end
      end
    end

    # A write refuses url credentials, but a read masks only the secret in
    # them, since the rest of a URL says where it is used.
    context "when a dotenv value is a url holding credentials" do
      it "masks only the password, not the whole url" do
        line = "export DATABASE_URL='postgres://app:hunter2xyz@db.local/app'"

        expect(detect(line).map { [_1.bytes, _1.reason] }).to eq([["hunter2xyz", "url credentials"]])
      end
    end

    context "when a dotenv name ends in the short password word" do
      it "masks only the value of MYSQL_PWD, bare or quoted" do
        expect(detect("MYSQL_PWD=hunter2pass").map(&:bytes)).to eq(["hunter2pass"])
        expect(detect("MYSQL_PWD='hunter2pass'").map(&:bytes)).to eq(["hunter2pass"])
      end

      # The hint is the upper-case `_PWD` of a variable name, not the word, and
      # a command substitution says where a value is read from.
      ["original_pwd = Dir.pwd", "ORIG_PWD=$(pwd)"].each do |line|
        it "reports nothing for #{line}" do
          expect(detect(line)).to be_empty
        end
      end
    end

    it "masks nothing in a query string holding an email address" do
      expect(detect("http://localhost:3000?email=tara@example.com")).to be_empty
    end

    # The literal assignment and the password variable rank after the named
    # shapes, so a line they all see keeps the name it had before them.
    it "names a mid-line compound password assignment by the literal shape" do
      expect(detect("then set DB_PASSWORD=hunter2pass").map(&:reason)).to eq(["credential literal assignment"])
    end

    context "when a password shape holds a reference, a template or a plain word" do
      {
        "an env reference" => "x_password: ${DB_PASS}",
        "an erb template" => "x_password: <%= ENV['X'] %>",
        "a json reference" => '{"password": "${PASS}"}',
        "a json null" => '{"password": null}',
        "a json true" => '{"password": true}',
        "a short json word" => '{"password": "none"}',
        "a url reference" => 'url = "postgres://app:${PW}@db/x"',
        "a url with an empty password" => "postgres://app:@db/x",
        "a url with a user and no password" => "https://user@host/path",
        "a url with a port only" => "https://example.com:8080/path",
        "a password hint key" => '{"password_hint": "your pet"}',
        "ssh port flag" => "ssh -p 22 host",
        "git log patch flag" => "git log -p",
        "mysql prompt flag" => "mysql -u root -p",
        "mysql prompt flag then option" => "mysql -u root -p -e 'select 1'"
      }.each do |label, line|
        it "reports nothing for #{label}" do
          expect(detect(line)).to be_empty
        end
      end
    end

    context "when a credential line names where the secret is read from" do
      [
        "password: ${DB_PASS}",
        'token = ENV.fetch("GITHUB_TOKEN")',
        'password: ENV["X_PASS"]',
        "password: ${{ secrets.DB_PASS }}",
        "password: $DB_PASS",
        '{"password": "${{ secrets.DB_PASS }}"}',
        "password: <%= ENV['X_PASS'] %>",
        "#   password: Rails.application.credentials.dig(:smtp, :password),"
      ].each do |line|
        it "reports nothing for #{line}" do
          expect(detect(line)).to be_empty
        end
      end

      [
        ["DB_PASSWORD=${DB_PASSWORD:-hunter2pass}", "hunter2pass"],
        ["password: $hunter2pass", "hunter2pass"],
        ["DB_PASSWORD=$ecretHunter2", "ecretHunter2"],
        ["password: ENV[hunter2pass", "hunter2pass"],
        ["password: <%hunter2pass", "hunter2pass"],
        ["password: ${DB_PASS}hunter2pass", "hunter2pass"],
        ['{"password": "$hunter2pass"}', "hunter2pass"],
        ['{"password": "${X:-hunter2pass}"}', "hunter2pass"],
        ["password: ENV[hunter2pass]", "ENV[hunter2pass]"],
        ["password: ENV[:hunter2pass]", "ENV[:hunter2pass]"],
        [%q(password: ENV['hunter2pass"]), %q(ENV['hunter2pass"])],
        ["password: Rails.application.credentials.dig(:smtp,hunter2pass)", "hunter2pass"],
        ["password: Rails.application.credentials.hunter2pass", "hunter2pass"]
      ].each do |line, secret|
        it "still masks the secret in #{line}" do
          expect(detect(line).map(&:bytes).join).to include(secret)
        end
      end

      # Accepted: `$DB_PASS` is the common shape, so a dull all-caps value after `$` goes unmasked.
      it "accepts the miss on a low-entropy all-caps value after a dollar sign" do
        expect(detect("password: $HUNTERTWOPASS")).to be_empty
      end

      it "still masks a real value in a comment" do
        expect(detect("# password: hunter2pass").map(&:bytes)).to eq(["hunter2pass"])
      end

      it "still masks a real token inside a reference" do
        token = "ghp_#{"aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gH3jK5"[0, 36]}"
        expect(detect("password: ${#{token}}").map(&:bytes).join).to include(token)
      end
    end

    # No clean regex tells `-pager` from `-ppager`, and a false mask costs one
    # release decision; these pin the accepted cost.
    context "when a word merely looks like a value" do
      {
        "a mysql long-ish option" => ["mysql --help -pager less", "ager"],
        "a required marker" => ["confirm_password: required", "required"]
      }.each do |label, (line, value)|
        it "accepts the false positive on #{label}" do
          expect(detect(line).map(&:bytes)).to eq([value])
        end
      end
    end

    context "when url credentials have an empty user" do
      it "masks the password" do
        expect(detect("redis://:hunter2xyz@host:6379").map(&:bytes)).to eq(["hunter2xyz"])
      end
    end

    context "when a bare github token sits in prose" do
      %w[
        ghp_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5
        github_pat_11ABCDEFG0aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7dE9fG1hJ3kL5mN7pQ9rS1tU3vW5xY
      ].each do |token|
        it "names #{token[0, 6]} as a pattern, not entropy" do
          regions = detect("Use #{token} to log in.")

          expect(regions.map(&:bytes)).to eq([token])
          expect(regions.map(&:detector)).to eq([:pattern])
        end
      end
    end

    context "when a line only resembles a password shape" do
      {
        "a mkdir flag" => "mkdir -p build",
        "a compiler flag" => "gcc -pthread main.c",
        "a plain url" => "https://example.com/path",
        "a url with a port and no user" => "http://db.local:5432/app",
        "a policy setting" => "password_policy: strict"
      }.each do |label, line|
        it "reports nothing for #{label}" do
          expect(detect(line)).to be_empty
        end
      end
    end

    context "when an assignment is ordinary code or prose" do
      {
        "an integer assignment" => "x = 1",
        "a boolean constant" => "DEBUG = true",
        "a colon in prose" => "Note: this is important",
        "a toml setting" => 'format = "terse"',
        "an rspec let" => 'let(:path) { "a/b" }',
        "a uuid fixture" => "id = 550e8400-e29b-41d4-a716-446655440000",
        "a long file path" => "spec/lain/frontend/neovim/inbox_view_spec.rb",
        # Long, hex-legal and entirely predictable -- the padding run that a
        # threshold of zero would report and a threshold worth having will not.
        "a run of zero bytes written as hex" => "0000000000000000000000000000",
        "a repeated hex nibble" => "abababababababababababababab"
      }.each do |label, line|
        it "reports nothing for #{label}" do
          expect(detect(line)).to be_empty
        end
      end
    end

    # A value-shape test alone cannot see this, which is why the name is matched
    # too -- and matched as a SUBSTRING, because `DATABASE_PASSWORD` has no word
    # boundary before `PASSWORD`.
    context "when a compound name assigns a short, low-entropy secret" do
      it "reports it anyway" do
        regions = detect("DATABASE_PASSWORD=hunter2pass\n")

        expect(regions.map(&:bytes)).to eq(["hunter2pass"])
      end

      it "reports a passphrase no entropy threshold would reach" do
        expect(detect("SESSION_SECRET=correct-horse-battery-staple\n").map(&:bytes))
          .to eq(["correct-horse-battery-staple"])
      end

      # `hunter2` is seven bytes and is the exact case the name-substring gate was
      # argued from, so a floor that discards it would delete the recall the gate
      # exists to buy. The floor is pinned from both sides here: seven bytes is
      # reported, five is not.
      it "reports the seven-byte value the gate was designed around" do
        expect(detect("DATABASE_PASSWORD=hunter2\n").map(&:bytes)).to eq(["hunter2"])
      end

      it "misses a name-gated value below the substance floor" do
        expect(detect("DATABASE_PASSWORD=hunt1\n")).to be_empty
      end

      # Six exactly. Without this the floor is only pinned to the range [6, 7] --
      # `hunter2` is seven bytes, so a floor of 7 satisfies every other example
      # here while measurably changing 15 regions across the repo.
      it "reports a six-byte value, which is the floor itself" do
        expect(detect("DATABASE_PASSWORD=hunt12\n").map(&:bytes)).to eq(["hunt12"])
      end
    end

    # Every line here is real, taken from this repository, and every one produced
    # a region before the substance floor. Each becomes a prompt reading
    # "release the value `)`?" -- which is what makes a name hint over a trivial
    # value worse than useless: it spends the human's attention budget on syntax.
    context "when a name hint sits over a value with no substance" do
      {
        "a keyword argument whose value is elsewhere" =>
          "@config = config || build_config(api_key:, api_base:)",
        "a hash rocket in a YARD comment" =>
          "# @param prices [Hash{String=>Price}] family/model token => Price",
        "a zero in a keyword list" =>
          "cache_creation_input_tokens: 0, cache_read_input_tokens: 0)",
        "an integer constant" => "DEFAULT_MAX_TOKENS = 1024",
        "a closing brace" => "TOKENS = {",
        # Long enough to clear the byte floor on punctuation alone, which is why
        # the floor also requires an alphanumeric.
        "a separator constant" => 'SECTION_TOKEN = "========"'
      }.each do |label, line|
        it "reports nothing for #{label}" do
          expect(detect(line)).to be_empty
        end
      end
    end

    context "when a name that does not name a secret holds an ordinary value" do
      [
        "token_count = 123456",
        'token_count = "123456"',
        "session_id = blake3:abc123def456",
        "session_dir=/tmp/foo-bar"
      ].each do |line|
        it "reports nothing for #{line}" do
          expect(detect(line)).to be_empty
        end
      end

      it "still masks a full-length digest, which only a short one escapes" do
        hex = "9f2c4a0e1b7d3f5a6c8e0b2d4f6a8c0e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3"

        expect(detect("session_id = blake3:#{hex}").map(&:bytes).join).to include(hex)
      end
    end

    context "when a name that names a secret holds a number, a digest or a path" do
      [
        "PASSWORD=12345678", "passwd=00000000", "OTP_SECRET=12345678", "DB_PASSWORD=987654321",
        "SESSION_SECRET=1234567890123456", "PASSWORD=\"123456\"", "PIN_TOKEN=482913", "API_KEY=12345678",
        "PASSWORD=/hunter2/pass", "SECRET=/xK9Zq8pR2vLmN4tYw7", "AUTH_TOKEN=/etc/x",
        "export CREDENTIALS=/home/x/.aws/creds", "HOST_PWD=/home/tara/dev/lain", "private_checkout=/srv/private/w1",
        "PASSPHRASE=12345678", "ssh_passphrase=12345678", "DBPASSWORD=12345678", "userpass=12345678",
        "API_KEY=sha256:9f2c4a0e1b7d", "TOKEN=sha1:abcdef0123", "SECRET_KEY=0123456789abcdef"
      ].each do |line|
        it "still masks #{line}" do
          expect(detect(line)).not_to be_empty
        end
      end

      it "masks only the value of DATABASE_PASSWORD and SESSION_SECRET" do
        expect(detect("DATABASE_PASSWORD=hunter2").map(&:bytes)).to eq(["hunter2"])
        expect(detect("SESSION_SECRET=Zq8x!pR2vL").map(&:bytes)).to eq(["Zq8x!pR2vL"])
      end

      it "still masks an issuer token under a hinted name" do
        expect(detect("API_TOKEN=#{secret}").map(&:bytes)).to eq([secret])
      end
    end

    # A `.env` read through `git diff` puts a `+` or `-` before every line, and
    # the line-anchored shapes are the only ones that reach a short value.
    context "when an assignment sits on a diff line" do
      ["SESSION_ID=abc12345xyz", "AUTH=hunter2hunter2", "db_password: hunter2pass",
       %(db-session = "hunter2pass"), "config: kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3"]
        .product(%w[+ - ++]).each do |line, mark|
        it "finds the same region in #{"#{mark}#{line}".inspect} as without the #{mark}" do
          plain = detect("#{line}\n").map { [_1.bytes, _1.reason] }

          expect(plain).not_to be_empty
          expect(detect("#{mark}#{line}\n").map { [_1.bytes, _1.reason] }).to eq(plain)
        end
      end

      # An indented `.env` line in a diff is missed too: indented after a mark, the line is code.
      %w[+ -].each do |mark|
        it "leaves an indented line of code after a #{mark} alone" do
          expect(detect("#{mark}      forked_session = fork_of(parent)\n")).to be_empty
        end
      end
    end

    # Each prefix is joined to its value here, so no vendor-shaped literal sits in the tree.
    context "when a Stripe key has a short value" do
      %w[sk_live_ sk_test_ rk_live_ rk_test_ whsec_].each do |prefix|
        it "finds #{prefix} by its issuer shape" do
          key = "#{prefix}Zx9Qw8Lm2P"

          expect(detect("deploy with #{key} today\n"))
            .to contain_exactly(have_attributes(bytes: key, reason: "stripe key"))
        end
      end

      it "does not find a prefix run into a longer word" do
        expect(detect("bookmark_test_Zx9Qw8Lm2P and ask_live_Zx9Qw8Lm2P\n")).to be_empty
      end

      it "does not find a value shorter than 8 characters" do
        expect(detect("deploy with #{%w[sk_live_ Zx9Qw8L].join} today\n")).to be_empty
      end
    end

    context "when a name ends in _KEY" do
      it "masks a short value under an upper-case name" do
        expect(detect("STRIPE_KEY=Zx9Qw8Lm2Pq\n").map(&:bytes)).to eq(["Zx9Qw8Lm2Pq"])
      end

      it "leaves a lower-case name alone" do
        expect(detect("sort_key=Zx9Qw8Lm2Pq\n")).to be_empty
      end

      it "leaves a glued value of letters alone" do
        expect(detect("SIGNING_KEY=default_signer\n")).to be_empty
      end

      it "leaves a constant assigned with spaces alone" do
        expect(detect(%(CACHE_KEY = "lain_cache_v2"\nRUBY2_KEYWORDS_KEY = "_aj_ruby2_keywords"\n))).to be_empty
      end

      it "leaves a constant naming a plain word alone" do
        expect(detect(%(  HEADER_KEY = "writer"\n  ENV_KEY = "LAIN_PROVIDER_CONCURRENCY"\n))).to be_empty
      end
    end

    # Quotes belong to the file's syntax, not to the secret. Including them would
    # split one secret across two digests -- quoted and unquoted differ, so the
    # digest cache misses -- and, decisively, masking a span that carries its own
    # delimiters destroys the quoting that made the file parse.
    context "when a value is quoted" do
      let(:double) { %(API_KEY="#{secret}"\n) }
      let(:single) { %(API_KEY='#{secret}'\n) }

      it "excludes double quotes from the region" do
        expect(detect(double).map(&:bytes)).to eq([secret])
      end

      it "excludes single quotes from the region" do
        expect(detect(single).map(&:bytes)).to eq([secret])
      end

      it "digests a quoted value identically to an unquoted one" do
        expect(digests(double)).to eq(digests("API_KEY=#{secret}\n"))
      end

      it "leaves the file parseable when the region is masked" do
        region = detect(double).first
        masked = double.dup.tap { _1[region.start, region.length] = "<redacted:1>" }

        expect(masked).to eq(%(API_KEY="<redacted:1>"\n))
      end
    end

    # The yaml shape needs only a colon and a space, so its NAME arm would admit
    # any `word: text` line in prose or code. Value-shape only for it.
    context "when a yaml-shaped line carries a credential-ish name" do
      # The first word of the value has to clear the substance floor on its own,
      # or the floor kills this line whether or not yaml keeps its name arm --
      # and then the example proves nothing about the arm.
      it "reports nothing on the strength of the name alone" do
        expect(detect("session: correlation identifier for the run\n")).to be_empty
      end

      it "still reports when the value is secret-shaped" do
        expect(detect("config: #{secret}\n").map(&:bytes)).to eq([secret])
      end

      # Nothing real is lost by dropping yaml's name arm: a genuinely named
      # credential is matched by `credential assignment` directly, and a real
      # secrets.yml is gated by PATH before its content is ever read.
      it "still reports a named credential through the credential-assignment shape" do
        expect(detect("password: hunter2pass\n"))
          .to contain_exactly(have_attributes(reason: "credential assignment", bytes: "hunter2pass"))
      end
    end

    # Measured, not asserted from taste. `for(:content)` alone matches 95 of this
    # repo's 134 markdown files -- the number the classifier's own docstring
    # records -- and 86.0% of `lib/` and 95.4% of `spec/`, which would make every
    # file the agent reads park a pending. These examples exist so a future
    # widening trips a spec rather than waiting to be re-measured.
    context "with real files from this repository" do
      def repo_path(name) = File.expand_path("../../../#{name}", __dir__)

      def repo_files(glob) = Dir.glob(File.expand_path("../../../#{glob}", __dir__))

      it "finds nothing in this project's own instructions" do
        expect(detect(File.binread(repo_path("CLAUDE.md")))).to be_empty
      end

      it "finds nothing in the credential table it consumes" do
        expect(detect(File.binread(repo_path("lib/lain/credential_patterns.rb")))).to be_empty
      end

      # The plan doc carries one deliberately fake Anthropic key and quotes a
      # fake compound assignment 3 times. Finding exactly those, each value
      # without its backtick, in a long prose document, is the positive and the
      # negative control in one assertion.
      it "finds only the sample credentials in the plan that specified them" do
        regions = detect(File.binread(repo_path("planning/archive/chunk-project-root-and-secret-boundary.md")))

        expect(regions.map(&:reason)).to eq(["openai-style api key"] + (["credential literal assignment"] * 3))
        expect(regions.first.bytes).to start_with("sk-ant-")
        expect(regions.drop(1).map(&:bytes)).to eq(["hunter2"] * 3)
      end

      # Measured at 6.0% of 599 files when this landed, against the 86.0% the
      # ungated shapes produce. The bound is a flood alarm rather than a fixture,
      # so it has headroom -- but only about half again, not the 3x it carried
      # when it was first calibrated at a rate of 11.7%.
      it "keeps the rate over this library's own source well under a flood" do
        sources = repo_files("lib/lain/**/*.rb")
        matched = sources.count { |file| detect(File.binread(file)).any? }

        expect(sources.size).to be > 500
        expect(matched.fdiv(sources.size)).to be < 0.09
      end
    end

    context "when a UTF-8 BOM precedes a key on line 1" do
      # Regexes anchor `^` BEFORE a BOM and a BOM is not `[ \t]`, so the
      # patterns cannot see line 1 at all. A dotenv file written by a Windows
      # editor is exactly where that matters, so the BOM is skipped here -- and
      # the offsets must still index the ORIGINAL bytes, or masking hits the wrong
      # span.
      # `SESSION=hunter2pass` is reachable ONLY by the line-anchored dotenv shape:
      # the value is too short and too dull for entropy, and `session` is not in
      # the write side's unanchored `credential assignment` vocabulary. So this
      # fixture fails outright if the BOM is not skipped, where `API_KEY=` would
      # have been found anyway by an unanchored shape and hidden the defect.
      let(:content) { "\xEF\xBB\xBFSESSION=hunter2pass\n".b }

      it "still finds the key" do
        expect(detect(content).size).to eq(1)
      end

      it "reports an offset into the original bytes" do
        region = detect(content).first

        expect(content.byteslice(region.start, region.length)).to eq("hunter2pass")
      end

      it "digests it identically to the same file without the BOM" do
        expect(digests(content)).to eq(digests("SESSION=hunter2pass\n"))
      end
    end

    context "when the bytes are UTF-16" do
      let(:dotenv) { "NAME=lain\nSESSION=hunter2pass\nAWS=AKIAQZ7R2M4X9TBL3KWE\n" }

      def utf16(text, order) = text.encode(order).b

      def found_in(bytes) = detect(bytes).map { bytes.byteslice(_1.start, _1.length) }

      {
        "UTF-16LE behind a byte order mark" => ["\xFF\xFE".b, Encoding::UTF_16LE],
        "UTF-16BE behind a byte order mark" => ["\xFE\xFF".b, Encoding::UTF_16BE],
        "UTF-16LE with no byte order mark" => ["".b, Encoding::UTF_16LE],
        "UTF-16BE with no byte order mark" => ["".b, Encoding::UTF_16BE]
      }.each do |label, (mark, order)|
        it "finds each secret in #{label}, at offsets into the bytes handed over" do
          bytes = mark + utf16(dotenv, order)

          expect(found_in(bytes)).to eq([utf16("hunter2pass", order), utf16("AKIAQZ7R2M4X9TBL3KWE", order)])
        end
      end

      it "names each region as the UTF-8 text names it" do
        expect(detect("\xFF\xFE".b + utf16(dotenv, Encoding::UTF_16LE)).map(&:reason))
          .to eq(detect(dotenv).map(&:reason))
      end

      it "starts every region on a character boundary" do
        bytes = "\xFF\xFE".b + utf16("é€ #{secret}\n", Encoding::UTF_16LE)

        expect(detect(bytes).map(&:start)).to all(be_even)
      end

      it "still finds a secret in the ASCII a UTF-16 text runs into" do
        bytes = "\xFF\xFE".b + utf16("NAME=lain\n", Encoding::UTF_16LE) + "API_KEY=#{secret}\n"

        expect(found_in(bytes)).to include(secret)
      end

      it "does not find a placeholder already standing in UTF-16" do
        expect(detect("\xFF\xFE".b + utf16("API_KEY=<redacted:1>\n", Encoding::UTF_16LE))).to be_empty
      end

      it "counts and numbers past the placeholders standing in UTF-16" do
        bytes = utf16("a <redacted:4> b <redacted:2>\n", Encoding::UTF_16LE)

        expect([described_class.placeholders(bytes), described_class.numbering_after(bytes).next]).to eq([2, 5])
      end

      it "finds a recurrence of a UTF-8 secret in UTF-16 text" do
        bytes = "\xFF\xFE".b + utf16("echo #{secret}\n", Encoding::UTF_16LE)

        expect(described_class.recurrences(bytes, [secret]).map { bytes.byteslice(_1.start, _1.length) })
          .to eq([utf16(secret, Encoding::UTF_16LE)])
      end

      it "finds no recurrence touching a placeholder standing in UTF-16" do
        bytes = utf16("<redacted:1>#{secret}\n", Encoding::UTF_16LE)

        expect(described_class.recurrences(bytes, ["<redacted:1>#{secret}"])).to be_empty
      end
    end

    context "when ordinary binary carries ASCII" do
      # Each holds its secret as plain ASCII inside the binary, so what the detector found before UTF-16
      # was read is a known offset, and a binary taken for UTF-16 would move or lose it.
      let(:assignment) { "API_KEY=#{secret}\n" }

      def png(text)
        chunk = ->(type, data) { [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N") }
        "\x89PNG\r\n\x1A\n".b + chunk.call("IHDR".b, [1, 1, 8, 2, 0, 0, 0].pack("NNC5")) +
          chunk.call("tEXt".b, "Comment\0#{text}".b)
      end

      def stored_gzip(text) = Zlib.gzip(text, level: Zlib::NO_COMPRESSION).b

      it "finds the same region in a PNG text chunk" do
        bytes = png(assignment)

        expect(detect(bytes).map { [_1.start, _1.bytes] }).to eq([[bytes.index(secret), secret]])
      end

      it "finds the same region in a stored gzip stream" do
        bytes = stored_gzip(assignment)

        expect(detect(bytes).map { [_1.start, _1.bytes] }).to eq([[bytes.index(secret), secret]])
      end
    end

    context "when the bytes are not decodable" do
      # `valid_encoding?` answers TRUE for every UTF-16 String, which then raises
      # Encoding::CompatibilityError -- NOT an ArgumentError -- out of the first
      # Regexp. The `Sensitivity.readable?` guard and the `for(:content)` encoding contract both
      # record it; this is the consumer that has to survive it.
      let(:utf16) { "API_KEY=#{secret}\n".encode(Encoding::UTF_16LE) }
      let(:binary) { Random.new(20_260_807).bytes(4096) }

      it "does not raise on UTF-16" do
        expect { detect(utf16) }.not_to raise_error
      end

      it "does not raise on random binary" do
        expect { detect(binary) }.not_to raise_error
      end

      it "returns a region set for each" do
        expect(detect(utf16)).to be_an(Array).and be_frozen
        expect(detect(binary)).to be_an(Array).and be_frozen
      end

      it "does not raise on invalid UTF-8" do
        expect { detect("key=\xC3\x28#{secret}") }.not_to raise_error
      end
    end

    context "when the same bytes are scanned twice" do
      let(:content) { "A=#{secret}\nnoise\nB=#{secret.reverse}\n" }

      it "returns equal region sets in the same order" do
        expect(detect(content)).to eq(detect(content))
        expect(detect(content).size).to eq(2)
      end

      # The COUNT is asserted alongside the order because a sort that reverses the
      # scan makes the coalescer swallow both regions into one, and a single
      # region is trivially "in ascending order".
      it "returns them in ascending offset order" do
        expect(detect(content).map(&:start))
          .to eq([content.byteindex(secret), content.byteindex(secret.reverse)])
      end

      # The shapes deliberately disagree with the offsets here: the entropy run
      # comes FIRST in the file but LAST in the table's precedence order. Sorting
      # candidates by anything other than offset reorders the output.
      it "orders by offset even when the earlier region has the lower precedence" do
        mixed = "#{secret}\nAPI_KEY=sk-abcdefghijklmnopqrst\n"

        expect(detect(mixed).map(&:reason))
          .to eq(["high-entropy token", "openai-style api key"])
        expect(detect(mixed).map(&:start)).to eq([0, mixed.byteindex("sk-")])
      end
    end

    # The literal shape is the newest and the least specific, so a token an
    # issuer shape names keeps that name even inside a compound assignment.
    it "names a quoted mid-line compound assignment of a github token by the token" do
      line = %(  "GITHUB_TOKEN=ghp_ZK1mQ8vR3xT5wL9nB2jH7yD4sA6fG0pEqW1z"\n)

      expect(detect(line).map(&:reason)).to eq(["github token"])
    end

    context "when one span is matched by several detectors at once" do
      # `API_KEY=sk-...` is a dotenv assignment, an openai-style key, a
      # credential assignment and a high-entropy run. One secret is one region.
      let(:content) { "API_KEY=sk-#{secret}\n" }

      it "reports one region, not one per detector" do
        expect(detect(content).size).to eq(1)
      end

      it "prefers the issuer-fixed name over the syntactic one" do
        expect(detect(content).first.reason).to eq("openai-style api key")
      end

      context "when the value is quoted and two shapes reach it" do
        let(:quoted) { %(token:"sk-abcdefghijklmnopqrst"\n) }

        it "still takes the name of the higher-precedence shape" do
          expect(detect(quoted).map(&:reason)).to eq(["openai-style api key"])
        end

        it "excludes the quotes from the merged span" do
          expect(detect(quoted).first.bytes).to eq("sk-abcdefghijklmnopqrst")
        end
      end

      # The precedence rule is only OBSERVABLE when the better-named shape starts
      # at a different byte, and excluding quotes collapsed the fixture that used
      # to provide that -- both candidates now begin together, so the example
      # above passes whether or not precedence is applied. `$` restores the offset
      # without a quote: `credential assignment` takes the whole value from `$`,
      # and `sk-` matches one byte later because `$` is neither `\w` nor `-` and
      # so does not trip the issuer shape's lookbehind.
      context "when the better-named shape starts LATER, with no quote involved" do
        let(:unquoted) { "token:$sk-abcdefghijklmnopqrst\n" }

        it "takes the name of the higher-precedence shape, not the earlier one" do
          expect(detect(unquoted).map(&:reason)).to eq(["openai-style api key"])
        end

        it "still spans from the earlier candidate's start" do
          expect(detect(unquoted).first.bytes).to eq("$sk-abcdefghijklmnopqrst")
        end
      end

      # Offsets are what masking works by, so the fold's geometry needs pinning
      # at the byte, not merely "one region came out".
      # `$` and `!` are both outside the entropy scanner's charset, so the
      # pattern's value span begins one byte EARLIER and ends one byte LATER than
      # the entropy run inside it. That makes the two ends independently
      # observable: a merge that took the later start, or the earlier finish,
      # changes the bytes.
      # No real shape abuts another (each ends at a delimiter), so the abutting
      # pair is handed in at the candidate seam.
      context "when two candidates touch with no byte between them" do
        let(:content) { "aaaabbbb\n" }

        before do
          allow(described_class).to receive(:candidates).and_return(
            [{ start: 0, finish: 4, reason: "r", detector: :pattern, rank: 0 },
             { start: 4, finish: 8, reason: "r", detector: :pattern, rank: 1 }]
          )
        end

        it "reports one region, because the pair is one slot" do
          expect(detect(content).map(&:bytes)).to eq(["aaaabbbb"])
        end
      end

      context "when two overlapping candidates begin and end at different offsets" do
        let(:content) { "AUTH_TOKEN=$#{secret}!\n" }

        it "reports one region spanning both" do
          expect(detect(content).map(&:bytes)).to eq(["$#{secret}!"])
        end

        it "takes the earlier start and the later finish" do
          region = detect(content).first

          expect(region.start).to eq(content.byteindex("$"))
          expect(region.start + region.length).to eq(content.byteindex("\n"))
        end
      end
    end

    # `String#b` returns a NEW, MUTABLE String, so `frozen_string_literal` does
    # not reach a constant built with it -- which is how `BOM` was born mutable.
    it "freezes its String constants" do
      strings = described_class.constants.map { described_class.const_get(_1) }.grep(String)

      expect(strings).not_to be_empty
      expect(strings).to all(be_frozen)
    end

    it "returns a deeply frozen set" do
      regions = detect("API_KEY=#{secret}\n")

      expect(regions).to be_frozen
      expect(regions).to all(be_frozen)
      expect(regions.map(&:bytes)).to all(be_frozen)
    end
  end

  describe ".detect over a masked text" do
    it "flags no value that is exactly a placeholder" do
      text = %("password": "<redacted:1>"\nDB_PASSWORD: "<redacted:2>"\nurl: https://u:<redacted:3>@host/\n)

      expect(detect(text)).to be_empty
    end

    it "still flags a real value beside a placeholder" do
      expect(detect("a_password: <redacted:1>\nB_TOKEN=#{secret}\n").map(&:bytes)).to eq([secret])
    end
  end

  describe ".numbering_after" do
    it "starts one past the highest placeholder present, however it repeats" do
      expect(described_class.numbering_after("<redacted:2> <redacted:7> <redacted:2>").take(2)).to eq([8, 9])
    end

    it "starts at 1 when no placeholder is present" do
      expect(described_class.numbering_after("nothing").first).to eq(1)
    end
  end

  describe ".spellings" do
    it "spells a value raw and as an escaped string literal holds it" do
      expect(described_class.spellings(%(pa"ss\\word))).to eq([%(pa"ss\\word).b, %(pa\\"ss\\\\word).b])
    end
  end

  describe ".placeholders" do
    it "counts every placeholder present, a repeat included" do
      expect(described_class.placeholders("<redacted:1> x <redacted:1> <redacted:12>")).to eq(3)
    end
  end

  describe ".detect over credential-file formats" do
    {
      "a netrc machine line" => ["machine h login u password hunter2hunter2", "hunter2hunter2"],
      "a pgpass entry" => ["db.example:5432:app:alice:s3cretpass", "s3cretpass"],
      "an htpasswd entry" => ["alice:$apr1$abc$0123456789abcdefghijk", "$apr1$abc$0123456789abcdefghijk"],
      "an msmtprc password line" => ["password s3cretpass", "s3cretpass"]
    }.each do |label, (line, value)|
      it "covers the secret value of #{label} with one region" do
        regions = detect("# header\n#{line}\n")

        expect(regions.map { _1.bytes.dup.force_encoding(Encoding::UTF_8) }).to eq([value])
      end
    end

    it "leaves prose that merely mentions a password alone" do
      expect(detect("Reset your password from the settings page.\nThe password is stored hashed.\n")).to be_empty
    end

    {
      "an escaped-colon pgpass host" => ['\:\:1:5432:db:user:pw', "pw"],
      "a netrc entry with password before login" => ["machine h password p4ssw0rd login u", "p4ssw0rd"],
      "a netrc default entry" => ["default login u password p4ssw0rd", "p4ssw0rd"]
    }.each do |label, (line, value)|
      it "covers the secret of #{label}" do
        expect(detect("#{line}\n").map { _1.bytes.dup.force_encoding(Encoding::UTF_8) }).to eq([value])
      end
    end

    [
      "12:30:45:foo:bar",
      "host:80:a:b:c:d:e",
      "daemon:*:18474:0:99999:7:::",
      "nobody:*:65534:65534:nobody:/nonexistent:/usr/bin/false",
      "root:x:0:0:root:/root:/bin/bash",
      "root:!:19000:0:99999:7:::",
      "the machine foo password reset",
      "default password reset"
    ].each do |line|
      it "reports no region for #{line.inspect}" do
        expect(detect("#{line}\n")).to be_empty
      end
    end
  end

  describe ".detect with checksums" do
    def checksummed(content) = detect(content, checksums: true)

    def hex(seed, bytes) = OpenSSL::Digest.hexdigest("SHA256", seed)[0, bytes * 2]
    def base64(seed, bytes) = [OpenSSL::Digest.digest("SHA512", seed)[0, bytes]].pack("m0")

    lockfile_lines = {
      "a Gemfile.lock checksum" => ->(s) { "  rake (13.0.6) sha256=#{s.hex("rake", 32)}\n" },
      "a Cargo.lock checksum" => ->(s) { "checksum = \"#{s.hex("serde", 32)}\"\n" },
      "a poetry.lock content hash" => ->(s) { "content-hash = \"#{s.hex("poetry", 32)}\"\n" },
      "a Pipfile.lock hash" => ->(s) { "                \"sha256:#{s.hex("pipfile", 32)}\"\n" },
      "a composer.lock shasum" => ->(s) { "                \"shasum\": \"#{s.hex("composer", 20)}\"\n" },
      "a yarn.lock resolved commit" => lambda { |s|
        "  resolved \"https://registry.yarnpkg.com/a/-/a-1.0.0.tgz##{s.hex("yarn", 20)}\"\n"
      },
      "a sha512 integrity" => ->(s) { "  integrity sha512-#{s.base64("npm", 64)}\n" },
      "a sha256 integrity" => ->(s) { "  integrity sha256-#{s.base64("npm256", 32)}\n" },
      "a go.sum h1 hash" => ->(s) { "golang.org/x/text v0.3.0 h1:#{s.base64("go", 32)}\n" },
      "a gem whose name holds a hint word" => ->(s) { "  omniauth (2.1.0) sha256=#{s.hex("omniauth", 32)}\n" },
      "a poetry.lock file hash" => lambda { |s|
        "    {file = \"a.tar.gz\", hash = \"sha256:#{s.hex("poetry-file", 32)}\"},\n"
      },
      "a Pipfile.lock meta hash" => ->(s) { "            \"sha256\": \"#{s.hex("pipfile-meta", 32)}\"\n" },
      "a package-lock.json integrity" => ->(s) { "      \"integrity\": \"sha512-#{s.base64("npm-json", 64)}\"\n" },
      "a pnpm-lock.yaml integrity" => ->(s) { "    resolution: {integrity: sha512-#{s.base64("pnpm", 64)}}\n" },
      "a composer.lock reference" => ->(s) { "                \"reference\": \"#{s.hex("composer-ref", 20)}\",\n" },
      "a Gemfile.lock git revision" => ->(s) { "  revision: #{s.hex("gem-git", 20)}\n" },
      "a Cargo.lock git source" => lambda { |s|
        "source = \"git+https://github.com/org/crate?branch=main##{s.hex("cargo-git", 20)}\"\n"
      }
    }

    # Lowercase hex of a digest's width with no hint before it reads as a digest by its shape alone.
    digest_shaped = ["a Gemfile.lock checksum", "a Cargo.lock checksum", "a poetry.lock content hash",
                     "a Pipfile.lock hash", "a composer.lock shasum", "a yarn.lock resolved commit",
                     "a poetry.lock file hash", "a Pipfile.lock meta hash", "a composer.lock reference",
                     "a Gemfile.lock git revision", "a Cargo.lock git source", "a gem whose name holds a hint word"]

    lockfile_lines.each do |label, line|
      it "reports no region for #{label}" do
        expect(checksummed(line.call(self))).to be_empty
      end
    end

    lockfile_lines.except(*digest_shaped).each do |label, line|
      it "still reports #{label} without checksums" do
        expect(detect(line.call(self))).not_to be_empty
      end
    end

    lockfile_lines.slice(*digest_shaped).each do |label, line|
      it "reports no region for #{label} without checksums either" do
        expect(detect(line.call(self))).to be_empty
      end
    end

    hinted = {
      "a JSON token" => ->(v) { "    \"token\": \"#{v}\",\n" },
      "a YAML _authToken" => ->(v) { "  _authToken: #{v}\n" },
      "a YAML session" => ->(v) { "  session: #{v}\n" },
      "a JSON api_key" => ->(v) { "  \"api_key\": \"#{v}\"\n" },
      "a YAML private_key" => ->(v) { "  private_key: #{v}\n" },
      "an npmrc _authToken" => ->(v) { "//registry.example/:_authToken=#{v}\n" },
      "a yarn v1 token" => ->(v) { "  token \"#{v}\"\n" },
      "a quoted YAML token" => ->(v) { "  token: \"#{v}\"\n" }
    }

    hinted.each do |label, line|
      it "still masks a hex64 value under #{label}" do
        value = hex(label, 32)

        expect(checksummed(line.call(value)).map(&:bytes)).to include(value)
      end
    end

    # A checksum word or algorithm prefix counts only where a field starts, so it
    # cannot be smuggled in inside a hinted value or a longer key. Uppercase, so a
    # digest's lowercase shape is not what lets a line through.
    {
      "an algorithm prefix under a YAML private_key" => ->(h, _) { "  private_key: sha256:#{h}\n" },
      "a sha1 prefix under a JSON _authToken" => ->(_, h40) { "  \"_authToken\": \"sha1:#{h40}\"\n" },
      "a sha256= prefix under a JSON token" => ->(h, _) { "  \"token\": \"sha256=#{h}\"\n" },
      "a sha1= prefix under an npmrc _authToken" => ->(_, h40) { "//registry/:_authToken=sha1=#{h40}\n" },
      "a sha256= prefix under a YAML signature" => ->(h, _) { "  signature: sha256=#{h}\n" },
      "an integrity word inside a JSON token" => ->(h, _) { "  \"token\": \"integrity #{h}\"\n" },
      "a hash word after a token word" => ->(h, _) { "  token hash #{h}\n" },
      "a dotted auth.hash key" => ->(h, _) { "auth.hash = \"#{h}\"\n" },
      "a hash query parameter" => ->(h, _) { "  resolved \"https://registry.example/a.tgz?hash=#{h}\"\n" },
      "a JSON api_token_sha256 key" => ->(h, _) { "  \"api_token_sha256\": \"#{h}\"\n" },
      "a JSON auth-hash key" => ->(h, _) { "  \"auth-hash\": \"#{h}\"\n" },
      "a JSON session_checksum key" => ->(h, _) { "  \"session_checksum\": \"#{h}\"\n" },
      "a hash key after a comma with no space" => ->(h, _) { "  resolved \"https://r.example/a.tgz?a=1,hash=#{h}\"\n" },
      "a checksum word with no separator after it" => ->(h, _) { "  hash #{h}\n" },
      "an integrity word after another word" => ->(h, _) { "  token integrity #{h}\n" }
    }.each do |label, line|
      it "still masks #{label}" do
        value40 = hex(label, 20).upcase
        value64 = hex(label, 32).upcase
        regions = checksummed(line.call(value64, value40)).map(&:bytes).join(" ")

        expect([value64, value40].any? { regions.include?(_1) }).to be(true)
      end
    end

    # The rows whose nearest key names a secret, or hints at one with no algorithm
    # prefix between, so the lowercase digest shape does not excuse them either.
    {
      "an algorithm prefix under a YAML private_key" => ->(h, _) { "  private_key: sha256:#{h}\n" },
      "a sha1 prefix under a JSON _authToken" => ->(_, h40) { "  \"_authToken\": \"sha1:#{h40}\"\n" },
      "a sha256= prefix under a JSON token" => ->(h, _) { "  \"token\": \"sha256=#{h}\"\n" },
      "a sha1= prefix under an npmrc _authToken" => ->(_, h40) { "//registry/:_authToken=sha1=#{h40}\n" },
      "a dotted auth.hash key" => ->(h, _) { "auth.hash = \"#{h}\"\n" },
      "a JSON api_token_sha256 key" => ->(h, _) { "  \"api_token_sha256\": \"#{h}\"\n" },
      "a JSON auth-hash key" => ->(h, _) { "  \"auth-hash\": \"#{h}\"\n" },
      "a JSON session_checksum key" => ->(h, _) { "  \"session_checksum\": \"#{h}\"\n" }
    }.each do |label, line|
      it "still masks #{label} in lowercase" do
        value40 = hex(label, 20)
        value64 = hex(label, 32)
        regions = checksummed(line.call(value64, value40)).map(&:bytes).join(" ")

        expect([value64, value40].any? { regions.include?(_1) }).to be(true)
      end
    end

    %w[digest sha1 md5 commit].each do |word|
      it "reads a #{word} key as a checksum key" do
        value = hex(word, 32).upcase

        expect([checksummed("  #{word}: #{value}\n"), detect("  #{word}: #{value}\n").size]).to eq([[], 1])
      end
    end

    it "still masks an uppercase hex64 value no checksum key names" do
      value = hex("bare", 32).upcase

      expect(checksummed("  #{value}\n").map(&:bytes)).to eq([value])
    end

    it "reports no region for an old yarn.lock sha1 integrity" do
      expect(checksummed("  integrity sha1-#{base64("old-yarn", 20)}\n")).to be_empty
    end

    it "still masks a sha1 digest shape behind any key but integrity" do
      lines = ["  note sha1-#{base64("note", 20)}\n", "  checksum sha1-#{base64("checksum", 20)}\n",
               "  token: sha1-#{base64("token", 20)}\n"]

      expect(lines.map { checksummed(_1).size }).to all(eq(1))
    end

    it "still masks an h1 value outside a go.sum module line" do
      value = "h1:#{base64("loose-h1", 32)}"

      expect(checksummed("  x #{value}\n").map(&:bytes)).to eq([value.delete_prefix("h1:")])
    end

    it "still masks an SRI-shaped value no checksum key names" do
      value = "sha512-#{base64("unkeyed", 64)}"

      expect(checksummed("  pasted #{value}\n").map(&:bytes)).to eq([value])
    end

    it "still masks a checksum-shaped value under a name hint" do
      value = hex("hinted", 32)

      expect(checksummed("auth_token = \"#{value}\"\n").map(&:bytes)).to eq([value])
    end

    it "still masks an issuer-shaped token beside the hashes" do
      content = "  integrity sha512-#{base64("npm", 64)}\n  token: AKIAZ7QW3RT5YU8IOP2L\n"

      expect(checksummed(content).map(&:bytes)).to eq(["AKIAZ7QW3RT5YU8IOP2L"])
    end

    it "still masks a credential in a URL" do
      content = "\"resolved\": \"https://user:t0k3nV4lu3x9@registry.example/a/-/a-1.0.0.tgz\"\n"

      expect(checksummed(content).map(&:bytes)).to eq(["t0k3nV4lu3x9"])
    end

    it "still masks a checksum shape glued onto more token bytes" do
      digest = base64("glued", 32)
      glued = ["#{hex("glued", 32)}ff", "xh1:#{digest}", "h1:#{digest}x", "sha512-#{base64("glued", 64)}x"]

      expect(glued.map { checksummed("value #{_1}\n").size }).to all(eq(1))
    end

    it "still masks a sha512 prefix over a digest of the wrong length" do
      expect(checksummed("  integrity sha512-#{base64("short", 32)}\n")).not_to be_empty
    end

    it "still masks a 50-hex run, which no checksum is" do
      expect(checksummed("value #{hex("fifty", 32)[0, 50]}\n")).not_to be_empty
    end
  end

  describe ".detect over content-addressed paths" do
    it "finds nothing in a cargo test runner line" do
      expect(detect("Running unittests src/lib.rs (target/debug/deps/word_count-46e9759e7fd1a230)")).to eq([])
    end

    it "finds nothing in nix store, docker overlay and huggingface snapshot paths" do
      paths = ["/nix/store/b6gvzjyb2pg0kjfwrjmg1vfhh54ad73z-firefox-33.1/bin/firefox",
               "/var/lib/docker/overlay2/9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08/diff/etc",
               "/home/u/.cache/huggingface/hub/models--Qwen--Qwen3-8B/snapshots/" \
               "a09a35458c702b33eeacc393d103063234e8bc28/config.json"]

      expect(paths.map { detect(_1) }).to eq([[], [], []])
    end

    it "still finds a random name beside a store hash" do
      paths = ["/nix/store/99z78g3bp6wcp3zvyq5hyjpkgp71s8aw-kyYkQLeM9SYCejEkarNcH4XUwLCrh4EnDkrVvs8f",
               "/hub/models--q4OcfcoKRsvjDlhedWm1vqbskfhiFY/snapshots/790011175d4b2d4056f53ca55913bcd5961b0014/config"]

      expect(paths.map { detect(_1).size }).to eq([1, 1])
    end

    it "still finds a random segment after a store path" do
      path = "/nix/store/2a44rhiqhi3dpqrf0259pbkf5k9krv3b-x/q4OWMDxU9jWPGJplU7cyegdl"

      expect(detect(path).size).to eq(1)
    end

    it "still finds a key-width hex segment in a URL" do
      keys = %w[9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 cf588750bd0289e64e97338301006fdc]
      urls = ["https://api.example.com/keys/#{keys[0]}/send", "https://hooks.example.com/notify/#{keys[1]}"]

      expect(urls.map { detect(_1).map(&:bytes) }).to match([[include(keys[0])], [include(keys[1])]])
    end

    it "still finds a random mixed-case path segment" do
      expect(detect("files/Xk9mP2qR7vL4nT8wZ3bY6cH1/data").map(&:bytes)).to eq(["files/Xk9mP2qR7vL4nT8wZ3bY6cH1/data"])
    end
  end

  describe ".detect over-masking" do
    def over_masked_reason(shape) = "over-masked: #{shape} could not be scanned to the end"

    # 1.2 MB of a near miss for `quoted password key` runs past fancy-regex's default backtrack limit,
    # and its higher one finishes it.
    it "retries a shape the default backtrack limit cannot finish" do
      text = "#{%({"db_password": "short"}\n) * 50_000}#{%({"db_password": "#{"Zq8vLm2xK9" * 2}"}\n)}"
      found = described_class.detect(text)

      expect(found.map(&:over_masked_by).uniq).to eq([nil])
      expect(found.size).to eq(1)
    end

    # A 1.2 MB run of `github_pat_` overflows fancy-regex's backtracking stack at any limit.
    it "over-masks the one line a single-line shape cannot finish, and masks the other 9 as before" do
      lines = ["# config", "AWS=AKIAABCDEFGHABCDEFGH", "name = lain", "", "github_pat_" * 110_000,
               "API_KEY=#{secret}", "plain prose", "x = 1", "PGPASSWORD=#{secret.reverse} psql", "end"]
      text = "#{lines.join("\n")}\n"
      at = text.index(lines[4])

      found = described_class.detect(text)
      over, rest = found.partition(&:over_masked_by)

      expect(over.map { [_1.start, _1.bytes, _1.reason, _1.over_masked_by] })
        .to eq([[at, lines[4], over_masked_reason("github token"), "github token"]])
      expect(rest.map(&:bytes)).to eq(["AKIAABCDEFGHABCDEFGH", secret, secret.reverse])
    end

    it "over-masks a multi-line shape it cannot finish from its BEGIN line to the end of the text" do
      body = [Random.new(7).bytes(870_000)].pack("m0").scan(/.{1,64}/).join("\n")
      text = "prose before\n-----BEGIN PUBLIC KEY-----\n#{body}\n-----END PUBLIC KEY-----\nafter\n"
      begin_at = text.index("-----BEGIN")

      found = described_class.detect(text)

      expect(text.bytesize).to be > 1_170_000
      expect(found.select(&:over_masked_by).map { [_1.reason, _1.over_masked_by] })
        .to eq([[over_masked_reason("PEM_PUBLIC"), "PEM_PUBLIC"]])
      expect(found.any? { _1.start <= begin_at && _1.start + _1.length == text.bytesize }).to be(true)
    end

    # The block before it is a real public key, so it is exempt and no region of its own touches the
    # over-masked span: what is left plain is exactly that finished match.
    it "over-masks a multi-line shape from the end of its last finished match" do
      public_key = "-----BEGIN PUBLIC KEY-----\n" \
                   "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEEqLZqfP50K+z6ugZCcMvznsfNKm3\n" \
                   "kGLxuY1KbqTsdEfeoCI93bNaaDVQwitfuWhftAwhK9qnoloVYfeVgSPu3g==\n" \
                   "-----END PUBLIC KEY-----"
      text = "#{public_key}\n-----BEGIN PUBLIC KEY-----\n#{"A" * 1_100_000}-----END RSA PUBLIC KEY-----\n"

      expect(described_class.detect(text).map { [_1.start, _1.length, _1.over_masked_by] })
        .to eq([[public_key.bytesize, text.bytesize - public_key.bytesize, "PEM_PUBLIC"]])
    end
  end

  describe Lain::Sensitivity::Regions::Region do
    def region(bytes) = described_class.new(start: 0, bytes:, reason: "dotenv assignment", detector: :pattern)

    context "when two regions differ only by a backslash escape" do
      # Raw bytes, never routed through `Canonical.digest`: a JSON-native
      # canonicalization normalizes away exactly the difference the key exists
      # to keep. `review/hunk.rb:10-14` settles the identical question.
      let(:escaped) { region('value="a\\nb"') }
      let(:literal) { region(%(value="a\nb")) }

      it "digests them differently" do
        expect(escaped).not_to have_same_digest_as(literal)
      end
    end

    # The escaped/literal pair above differs in LENGTH as well as in content, so
    # on its own it cannot tell a digest of the bytes from a digest of the byte
    # count. This pair is the same length and different bytes.
    it "digests two same-length, different-byte regions differently" do
      expect(region("sk-aaaaaaaaaaaaaaaaaaaa").digest).not_to eq(region("sk-aaaaaaaaaaaaaaaaaaab").digest)
    end

    it "digests bytes that JSON cannot encode" do
      expect { region("\xC3\x28\xFF".b).digest }.not_to raise_error
    end

    # The framing is what keeps a region's address in its own namespace. Without
    # the scheme word a region digest IS a snapshot blob digest of the same bytes;
    # without any framing it is the bare hash every unframed hasher produces. Both
    # halves are asserted, because dropping either one leaves the other passing.
    it "does not collide with a snapshot blob of the same bytes" do
      bytes = "sk-#{secret}"

      expect(region(bytes).digest).not_to eq(Lain::Workspace::Snapshot::Blob.new(bytes:).digest)
    end

    it "does not collide with the bare hash of the same bytes" do
      bytes = "sk-#{secret}"

      expect(region(bytes).digest).not_to end_with(Lain::Ext.blake3_hex(bytes))
    end

    it "carries the digest algorithm in the digest" do
      expect(region("x").digest).to start_with("#{Lain::Canonical::DIGEST_ALGORITHM}:")
    end

    # A golden vector, and the only assertion that can see the whole framing at
    # once: scheme word, separating space, decimal length, NUL, then the bytes.
    # Every structural mutation is invisible to a start/length assertion --
    # dropping the NUL alone changes 668 digests across this repo and no
    # behavioural example notices. These digests are persisted, so the framing
    # is a wire contract from here on and a change to it is a migration, not a
    # refactor. Recompute deliberately if you ever mean to break it.
    it "addresses known bytes to a known digest" do
      expect(described_class.address("hunter2".b))
        .to eq("blake3:f1010ca332b93af2b0570d5715aca66d73c63a9ba10207b42641d7e8c9192aa3")
    end

    # The cache keys BY digest and asks for it in a loop, so it is computed once
    # at construction the way `Snapshot::Blob` does it. Counting the hash calls is
    # the only honest check: `-str` interns, so comparing object identity would
    # pass whether or not anything was memoized.
    it "hashes its bytes exactly once however often the digest is asked for" do
      allow(Lain::Ext).to receive(:blake3_hex).and_call_original

      subject = region("sk-#{secret}")
      3.times { subject.digest }

      expect(Lain::Ext).to have_received(:blake3_hex).once
    end

    # What actually needs pinning about the stored bytes. Asserting that `.b` does
    # not change the digest, or that `length == bytesize`, is true of every String
    # by construction and cannot fail -- these can.
    it "stores its bytes as frozen BINARY whatever encoding they arrive in" do
      stored = region("héllo").bytes

      expect(stored.encoding).to eq(Encoding::BINARY)
      expect(stored).to be_frozen
      expect(stored.bytesize).to eq(6)
    end

    # A region's bytes are the one thing that must never reach a log or the
    # NDJSON Journal by accident; `spec/output_discipline_spec.rb` exists because
    # one stray byte in that stream was a real incident.
    it "names no shape it was over-masked for, unless one is given" do
      over = described_class.new(start: 0, bytes: "x", reason: "over-masked: TOKEN could not be scanned to the end",
                                 detector: :pattern, over_masked_by: "TOKEN")

      expect(region("x").over_masked_by).to be_nil
      expect(over.over_masked_by).to eq("TOKEN")
      expect(over).to be_deeply_frozen
    end

    it "withholds its bytes from inspect and to_s" do
      bytes = "sk-#{secret}"
      subject = region(bytes)

      expect(subject.inspect).not_to include(bytes)
      expect(subject.to_s).not_to include(bytes)
      expect(subject.inspect).to include("dotenv assignment")
    end

    # `Ext.blake3_hex` is not ractor-safe -- the same recorded gap
    # `review/hunk.rb:17` pins for Hunk. Digesting eagerly moves that constraint
    # from every READ of the digest to the single CONSTRUCTION, which is the
    # whole benefit: a Region can now be handed to another Ractor and still
    # answer for its own identity. Both halves are pinned, because the useful one
    # is the half that now works.
    describe "Ractor usability" do
      it "is shareable" do
        expect(region("sk-#{secret}")).to be_deeply_frozen
      end

      it "answers for its digest off the main Ractor" do
        subject = region("sk-#{secret}")

        expect(Ractor.new(subject, &:digest).value).to eq(subject.digest)
      end

      it "can only be constructed on the main Ractor" do
        expect { Ractor.new { described_class.new(start: 0, bytes: "sk-x", reason: "r", detector: :pattern) }.value }
          .to raise_error(Ractor::RemoteError)
      end
    end
  end
end
