# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# What a survey may SEE of a file it is allowed to list.
#
# Joel's ruling (2026-08-09): a gated file enters the corpus redacted to its
# released regions. Withholding it wholesale makes a survey stricter than the
# read path over the same file; entering it whole makes it looser. So every
# listed file is projected -- ordinary ones too, because a path rule
# structurally cannot see a key pasted into `notes.txt`.
#
# The fixtures below are literal and obviously fake, and no path here is opened:
# the projection is a pure function of (path, bytes) and the run's one ledger.
RSpec.describe Lain::Survey::Projection do
  subject(:projection) { described_class.new(ledger:) }

  let(:ledger) { Lain::Sensitivity::Ledger.new }
  let(:path) { "/repo/.env" }
  # Literal, never sliced from the detector's own tables: a fixture built out of
  # the constant it is meant to pin cannot fail when that constant is wrong.
  let(:api_key) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }
  let(:password) { "hunter2SecretValue" }
  let(:session_secret) { "correct-horse-battery-staple" }
  let(:dotenv) { "API_KEY=#{api_key}\nDATABASE_PASSWORD=#{password}\nSESSION_SECRET=#{session_secret}\n" }

  def placeholder(ordinal) = format(Lain::Sensitivity::Regions::PLACEHOLDER, ordinal)

  def regions_in(content) = Lain::Sensitivity::Regions.detect(content)

  describe "a gated file entering masked" do
    it "keeps the structure a human reviews and withholds only the values" do
      projected = projection.project(path, dotenv)

      expect(projected).to include("API_KEY=", "DATABASE_PASSWORD=", "SESSION_SECRET=")
      expect(projected).not_to include(api_key, password, session_secret)
    end

    it "stands one placeholder in for each value, numbered in reading order" do
      expect(projection.project(path, dotenv))
        .to eq("API_KEY=#{placeholder(1)}\nDATABASE_PASSWORD=#{placeholder(2)}\nSESSION_SECRET=#{placeholder(3)}\n")
    end

    # By SHARED CONSTANT and not by a matching literal: the survey and the read
    # path must not drift on what a masked region looks like, and two copies of
    # the format is how they would.
    it "renders the read path's own placeholder" do
      expect(projection.project(path, dotenv)).to include(placeholder(1))
      expect(Lain::Sensitivity::Regions::PLACEHOLDER).to eq("<redacted:%d>")
    end

    # Both arms now render through {Sensitivity::Masking}, so this is an
    # integration pin rather than a drift guard: it says the survey reaches that
    # renderer with the same regions the read path does, which is the half the
    # shared object cannot enforce on its own.
    it "masks byte for byte as the read path's own scan does" do
      scan = Lain::Middleware::RedactSecretReads::Scan.new(dotenv)

      expect(projection.project(path, dotenv)).to eq(scan.mask(scan.regions))
    end
  end

  describe "a release" do
    it "is real bytes, while everything unreleased stays a placeholder" do
      ledger.release(path, [regions_in(dotenv).first])

      projected = projection.project(path, dotenv)

      expect(projected).to include(api_key)
      expect(projected).not_to include(password, session_secret)
    end

    it "renumbers what is left, so the ordinals still count masked regions" do
      ledger.release(path, [regions_in(dotenv).first])

      expect(projection.project(path, dotenv))
        .to eq("API_KEY=#{api_key}\nDATABASE_PASSWORD=#{placeholder(1)}\nSESSION_SECRET=#{placeholder(2)}\n")
    end

    # A release legitimately changes what the survey can show, so the unit keys
    # over the projection change with it and honestly demand a re-read. What is
    # pinned here is the half this object owns: the bytes move exactly where the
    # release was, and nowhere else.
    it "changes the projection only where the released region sits" do
      before_release = projection.project(path, dotenv)
      ledger.release(path, [regions_in(dotenv).last])

      after_release = projection.project(path, dotenv)

      expect(after_release.lines.first(2)).to eq(before_release.lines.first(2))
      expect(after_release.lines.last).not_to eq(before_release.lines.last)
    end
  end

  describe "a file the path rules called ordinary" do
    # The content boundary exists for exactly this: a path rule cannot see a key
    # pasted into a notes file, so the projection never asks what the path
    # classified as.
    it "is projected too, because a pasted key is a secret wherever it sits" do
      pasted = "Deploy notes\n\nAPI_KEY=#{api_key}\n\nAsk Sam before restarting.\n"

      projected = projection.project("/repo/notes.txt", pasted)

      expect(projected).not_to include(api_key)
      expect(projected).to include("Deploy notes", "Ask Sam before restarting.")
    end

    it "is handed back as it stands when it holds nothing sensitive" do
      ordinary = "x = 1\nDEBUG = true\nNote: this is important\n"

      expect(projection.project("/repo/app.rb", ordinary)).to eq(ordinary)
    end
  end

  describe "the ledger it is given" do
    # `complete: true` is sound precisely because a corpus reads WHOLE files.
    # Reconciling is what makes a secret deleted and later restored prompt
    # again rather than being sent on the strength of an old release.
    it "reconciles a release away when the file no longer holds that region" do
      ledger.release(path, regions_in(dotenv))
      projection.project(path, "API_KEY=\n")

      expect(projection.project(path, dotenv)).not_to include(api_key)
    end

    it "keeps a release across a projection that still holds the region" do
      ledger.release(path, [regions_in(dotenv).first])
      projection.project(path, dotenv)

      expect(projection.project(path, dotenv)).to include(api_key)
    end

    # The ledger is per-RUN and reaches every child, so it has no cwd to resolve
    # against and refuses a relative path. Delegated rather than re-checked:
    # a second absolute-path rule is a second answer.
    it "refuses a relative path, because two cwds behind one key is a release that travels" do
      expect { projection.project("notes.txt", dotenv) }.to raise_error(ArgumentError, /must be absolute/)
    end

    it "cannot be built without one, and there is deliberately no Null" do
      expect { described_class.new(ledger: nil) }.to raise_error(ArgumentError, /ledger is required/)
      expect { described_class.new }.to raise_error(ArgumentError)
    end
  end

  # `complete: true` is a promise about the BYTES, and this object cannot tell a
  # whole file from a chunk of one by looking. Where the caller holds a listing
  # it can say what the walk measured, and a disagreement is caught here rather
  # than surfacing much later as releases reconciled away and then re-masked
  # forever.
  describe "the whole-file promise" do
    it "refuses a partial read when the listing says how big the file was" do
      expect { projection.project(path, dotenv.byteslice(0, 20), size: dotenv.bytesize) }
        .to raise_error(ArgumentError, /whole file/)
    end

    it "projects when the bytes are the size the walk listed" do
      expect(projection.project(path, dotenv, size: dotenv.bytesize)).to include(placeholder(1))
    end

    it "projects without a size, because a caller holding no listing has nothing to check against" do
      expect(projection.project(path, dotenv)).to include(placeholder(1))
    end

    it "leaves the ledger untouched when it refuses, so a refusal reconciles nothing away" do
      ledger.release(path, [regions_in(dotenv).first])

      expect { projection.project(path, "API_KEY=\n", size: dotenv.bytesize) }.to raise_error(ArgumentError)
      expect(projection.project(path, dotenv)).to include(api_key)
    end
  end

  describe "bytes it must not corrupt" do
    it "keeps the file's encoding, because an offset into re-decoded text is a different offset" do
      utf8 = "# café\nAPI_KEY=#{api_key}\n"

      projected = projection.project(path, utf8)

      expect(projected.encoding).to eq(Encoding::UTF_8)
      expect(projected).to include("café")
    end
  end

  # Walk and projection are one admission policy: which paths enter, and which
  # bytes of them. A denied path is decided by the first half and no amount of
  # the second half brings it back -- denial is not approvable.
  describe "composed with the walk", :seam do
    let(:private_key) do
      "-----BEGIN OPENSSH PRIVATE KEY-----\n" \
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAM0ZBS0U\n" \
        "-----END OPENSSH PRIVATE KEY-----\n"
    end

    around do |example|
      Dir.mktmpdir("lain-survey-projection") { |made| @root = File.realpath(made) and example.run }
    end

    def write(relative, body)
      File.join(@root, relative).tap do |file|
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, body)
      end
    end

    it "never projects a denied path, so no survey artifact can carry it" do
      write(".ssh/id_ed25519", private_key)
      write(".env", dotenv)
      walk = Lain::Survey::Walk.new(root: @root, sensitivity: Lain::Sensitivity.new(home: "/home/surveyor", cwd: @root))

      projected = walk.files.to_h { |file| [file.path, projection.project(file.absolute, File.read(file.absolute))] }

      expect(projected.keys).to eq([".env"])
      expect(projected.values.join).not_to include(private_key, api_key)
      expect(walk.withheld.map(&:path)).to eq([".ssh/id_ed25519"])
    end
  end
end
