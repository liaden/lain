# frozen_string_literal: true

RSpec.describe Lain::Review::Verdict::Policy do
  # The narrowest duck a policy asks of a changeset, and it is deliberately the
  # SAME one `Marks#states` asks (`#base_ref`, `#hunks`) -- a policy reads the
  # tri-state through Marks and never derives it itself, so it cannot grow a
  # second, disagreeing derivation.
  def changeset(hunks:, base_ref: "base1") = Data.define(:base_ref, :hunks).new(base_ref:, hunks:)

  def hunk(path:, lines:)
    Lain::Review::Hunk.new(path:, old_start: 1, old_count: 1, new_start: 1, new_count: 1, lines:)
  end

  def marked(pairs, base_ref: "base1")
    pairs.reduce(Lain::Review::Marks.new(base_ref:)) { |marks, (key, state)| marks.mark(key, state) }
  end

  # One note as the journal holds it. `path`, `side` and `line` are where an
  # answer is delivered, `kind` decides what it claims, `drifted` decides how it
  # is named, and `id` is its identity; the rest is what {AnnotationPlaced}'s own
  # guard demands of any record at all, and is a constant here.
  def annotation(kind:, path: "a.rb", line: 3, side: "new", text: "this reads backwards", drifted: false)
    Lain::Review::AnnotationPlaced.new(id: SecureRandom.uuid, path:, side:, line:, anchor_text: "+a",
                                       text:, kind:, drifted:, revision: "r" * 40)
  end

  # a.rb has two hunks, b.rb one -- so "partially reviewed" is expressible for a
  # single file, which is what the card's own scenario asks for.
  let(:hunks) do
    [hunk(path: "a.rb", lines: ["+a"]), hunk(path: "a.rb", lines: ["+b"]), hunk(path: "b.rb", lines: ["+c"])]
  end
  let(:a_keys) { Lain::Review::Hunk.keys(hunks.select { |one| one.path == "a.rb" }) }
  let(:b_keys) { Lain::Review::Hunk.keys(hunks.select { |one| one.path == "b.rb" }) }
  let(:subject_changeset) { changeset(hunks:) }
  let(:blocker) { annotation(kind: "blocker") }

  describe "the port itself" do
    it "refuses to judge on its own, because admissibility is what a subclass IS" do
      expect do
        described_class.new.admit!("approve", changeset: subject_changeset, marks: marked([]), annotations: [])
      end.to raise_error(NotImplementedError, /admit!/)
    end

    it "names EveryHunk as the policy a session takes when nobody says otherwise" do
      expect(described_class.default).to be_a(described_class::EveryHunk)
    end

    it "raises a Lain::Error subclass, so a CLI boundary renders it rather than crashing" do
      expect(described_class::Incomplete.ancestors).to include(Lain::Error)
    end

    it "raises a Lain::Error subclass for a blocker too, so the same boundary renders that one" do
      expect(described_class::Blocked.ancestors).to include(Lain::Error)
    end

    # THE defect this card fixes, stated mechanically. A blocker could not block
    # because the notes were not among the arguments the question is asked with,
    # so no implementation -- present or future -- was able to read one. Pinned
    # on all FOUR, because a policy that quietly kept the old arity would go on
    # admitting over a blocker and look wired.
    it "asks every implementation about the annotations, not only the marks" do
      [described_class, described_class::EveryHunk, described_class::BlockersOnly,
       described_class::Permissive].each do |implementation|
        expect(implementation.instance_method(:admit!).parameters).to include(%i[keyreq annotations])
      end
    end

    it "derives both kinds it reads from the annotation vocabulary rather than restating the spellings" do
      expect(Lain::Review::ANNOTATION_KINDS).to include(described_class::BLOCKER).and include(described_class::ANSWER)
    end

    # P3, stated where a reader looks for the vocabulary rather than left to be
    # inferred from a fold: the third kind answers nothing.
    it "reads `question` as neither an objection nor an answer" do
      expect(Lain::Review::ANNOTATION_KINDS - [described_class::BLOCKER, described_class::ANSWER]).to eq(["question"])
    end
  end

  # What "unresolved" MEANS, in one place, so no policy grows a second answer.
  #
  # Annotations are a LOG, not a map, and the distinction is the whole of this
  # group. A mark is a map: the key MEANS "this hunk's state", re-marking is the
  # only gesture that touches it, so last-wins is what the key is for. A note is
  # an entry: every one of them is rendered, every one is its own act, and two
  # objections on one line are two objections. So identity here is
  # {AnnotationPlaced}'s own `id` -- what a surface already draws by -- and a
  # position is merely where an answer is DELIVERED. One answer, one objection,
  # oldest first.
  describe ".unresolved" do
    it "answers a blocker nobody has spoken to again" do
      expect(described_class.unresolved([blocker])).to eq([blocker])
    end

    it "answers nothing for notes and questions, which no policy refuses over" do
      expect(described_class.unresolved([annotation(kind: "note"), annotation(kind: "question", line: 9)]))
        .to be_empty
    end

    it "takes a later note on the same line as the answer, which is the gesture a human has" do
      expect(described_class.unresolved([blocker, annotation(kind: "note")])).to be_empty
    end

    # G4, and the reason identity is the id rather than the position: a diff
    # moves, two objections drift onto one line, and a fold keyed by position
    # collapses them into one -- so the earlier one vanishes from the refusal
    # while the surface goes on drawing both, by id. The two must not be able to
    # disagree.
    it "keeps two blockers on one line apart, because a position is not an identity" do
      second = annotation(kind: "blocker", text: "and this one too")

      expect(described_class.unresolved([blocker, second])).to eq([blocker, second])
      expect(described_class.unresolved([blocker, second]).map(&:id).uniq.size).to eq(2)
    end

    it "lets one note answer one blocker, oldest first, rather than clearing the line" do
      second = annotation(kind: "blocker", text: "and this one too")

      expect(described_class.unresolved([blocker, second, annotation(kind: "note")])).to eq([second])
    end

    it "clears a line once every blocker on it has an answer of its own" do
      second = annotation(kind: "blocker", text: "and this one too")
      answers = [annotation(kind: "note"), annotation(kind: "note", text: "and that one")]

      expect(described_class.unresolved([blocker, second, *answers])).to be_empty
    end

    # P3, decided rather than left to fall out of the fold: asking about
    # something is not answering it, so a `question` neither resolves a blocker
    # nor becomes one.
    it "does not let a question answer a blocker, because asking is not answering" do
      expect(described_class.unresolved([blocker, annotation(kind: "question")])).to eq([blocker])
    end

    it "keeps a blocker a later note on ANOTHER line cannot speak for" do
      expect(described_class.unresolved([blocker, annotation(kind: "note", line: 4)])).to eq([blocker])
    end

    it "keeps a blocker a later note in ANOTHER file cannot speak for" do
      expect(described_class.unresolved([blocker, annotation(kind: "note", path: "b.rb")])).to eq([blocker])
    end

    it "tells the two sides of one line apart, because they are two positions" do
      expect(described_class.unresolved([blocker, annotation(kind: "note", side: "old")])).to eq([blocker])
    end

    # An answer cannot precede its objection: the note below is spent on nothing
    # (there was no open blocker when it landed), and the blocker after it
    # stands.
    it "does not let a note answer a blocker placed after it" do
      expect(described_class.unresolved([annotation(kind: "note"), blocker])).to eq([blocker])
    end
  end

  describe described_class::EveryHunk do
    subject(:policy) { described_class.new }

    it "refuses an approve over a partially reviewed file, naming that file" do
      marks = marked([[a_keys.first, "reviewed"], [b_keys.first, "reviewed"]])

      expect { policy.admit!("approve", changeset: subject_changeset, marks:, annotations: []) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete, /a\.rb/)
    end

    it "does not name a file that IS fully reviewed" do
      marks = marked([[a_keys.first, "reviewed"], [b_keys.first, "reviewed"]])

      expect { policy.admit!("approve", changeset: subject_changeset, marks:, annotations: []) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete) do |error|
          expect(error.message).not_to include("b.rb")
        end
    end

    it "names every unreviewed file when nothing has been marked at all" do
      expect { policy.admit!("approve", changeset: subject_changeset, marks: marked([]), annotations: []) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete) do |error|
          expect(error.message).to include("a.rb").and include("b.rb")
        end
    end

    it "reports WHICH way each named file falls short, since partial and unreviewed call for different work" do
      marks = marked([[a_keys.first, "reviewed"]])

      expect { policy.admit!("approve", changeset: subject_changeset, marks:, annotations: []) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete) do |error|
          expect(error.message).to include("a.rb is partial").and include("b.rb is unreviewed")
        end
    end

    it "admits an approve once every hunk of every file is marked" do
      marks = marked((a_keys + b_keys).map { |key| [key, "reviewed"] })

      expect { policy.admit!("approve", changeset: subject_changeset, marks:, annotations: []) }.not_to raise_error
    end

    it "admits over a changeset with no hunks at all, because there is nothing left unreviewed" do
      expect { policy.admit!("approve", changeset: changeset(hunks: []), marks: marked([]), annotations: []) }
        .not_to raise_error
    end

    # The escape the `deferred` gate needs has to be REACHABLE from the refusal
    # itself: an unattended run that hits this wall gets one sentence, and the
    # sentence has to say what to swap.
    #
    # It names the FLAG and not this class. The sentence is echoed to a human
    # holding an editor -- `Handover#wrote_verdict` returns it and the lua half
    # puts it on the review rail -- and `Permissive.new` is a remedy only
    # somebody editing Ruby can perform. The negative is half the assertion:
    # a constructor reads as an instruction to whoever cannot tell it from one.
    it "points at the swap rather than only at the wall, in words its reader can act on" do
      expect { policy.admit!("approve", changeset: subject_changeset, marks: marked([]), annotations: []) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete) do |error|
          expect(error.message).to include("--permissive")
          expect(error.message).not_to match(/::|\.new\b/)
        end
    end

    # A work-scale changeset is thousands of files (research 3.7). Naming every
    # one of them turns a refusal into an unreadable wall, and the count is the
    # part a human acts on.
    it "caps how many files it names and says how many it did not" do
      many = (1..20).map { |number| hunk(path: format("f%02d.rb", number), lines: ["+#{number}"]) }

      expect { policy.admit!("approve", changeset: changeset(hunks: many), marks: marked([]), annotations: []) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete) do |error|
          expect(error.message).to match(/\b#{20 - described_class::NAMED_LIMIT} more\b/)
        end
    end

    it "derives its 'reviewed' comparison from Marks::REVIEWED rather than restating the spelling" do
      expect(described_class::REVIEWED).to eq(Lain::Review::Marks::REVIEWED.to_sym)
    end

    it "refuses a base it was not recorded against, rather than judging across a base change" do
      marks = marked((a_keys + b_keys).map { |key| [key, "reviewed"] }, base_ref: "other")

      expect { policy.admit!("approve", changeset: subject_changeset, marks:, annotations: []) }
        .to raise_error(Lain::Review::Marks::BaseMismatch)
    end

    # A blocker is the human's own refusal, and until this card it could not
    # refuse anything: the notes were not among `admit!`'s arguments, so the one
    # kind `ANNOTATION_KINDS` documents as the one a policy reads was read by
    # nobody.
    context "with a blocker on the diff" do
      let(:reviewed) { marked((a_keys + b_keys).map { |key| [key, "reviewed"] }) }

      it "refuses an approve over an unresolved blocker, naming the file and the line it is on" do
        expect { policy.admit!("approve", changeset: subject_changeset, marks: reviewed, annotations: [blocker]) }
          .to raise_error(Lain::Review::Verdict::Policy::Blocked) do |error|
            expect(error.message).to include("a.rb").and include("3")
          end
      end

      it "admits when every annotation is a plain note, which claims nothing about admissibility" do
        notes = [annotation(kind: "note"), annotation(kind: "question", line: 9)]

        expect { policy.admit!("approve", changeset: subject_changeset, marks: reviewed, annotations: notes) }
          .not_to raise_error
      end

      # The escape hatch this card had to build alongside the wall: without a
      # gesture that resolves one, a blocker is a review a human can never
      # settle. The gesture is a later note on the same line.
      it "admits once a later note on the same line has answered the blocker" do
        answered = [blocker, annotation(kind: "note", line: 3, text: "fixed in the follow-up")]

        expect { policy.admit!("approve", changeset: subject_changeset, marks: reviewed, annotations: answered) }
          .not_to raise_error
      end

      it "names the resolving gesture in the refusal, so the wall carries its own way out" do
        expect { policy.admit!("approve", changeset: subject_changeset, marks: reviewed, annotations: [blocker]) }
          .to raise_error(Lain::Review::Verdict::Policy::Blocked, /note/)
      end

      # A blocker is a human saying "not this", and unread files are a human not
      # having looked yet -- the first is the stronger statement, so it is the
      # one the refusal leads with.
      it "refuses on the blocker ahead of the unread files, and says so rather than listing them" do
        expect { policy.admit!("approve", changeset: subject_changeset, marks: marked([]), annotations: [blocker]) }
          .to raise_error(Lain::Review::Verdict::Policy::Blocked) do |error|
            expect(error.message).not_to include("unreviewed")
          end
      end

      # A base mismatch is a PRECONDITION, and it outranks both refusals above.
      # The marks belong to another diff -- and so do the blocker's own line
      # numbers, since an annotation is anchored in the diff it was authored
      # against. Refusing "answer the blocker at a.rb:3" over a position that is
      # not evidence sends a human to the wrong line and only walls them at the
      # real problem on the second try.
      it "refuses a base mismatch ahead of the blocker, whose line numbers name the other diff" do
        stale = marked((a_keys + b_keys).map { |key| [key, "reviewed"] }, base_ref: "other")

        expect { policy.admit!("approve", changeset: subject_changeset, marks: stale, annotations: [blocker]) }
          .to raise_error(Lain::Review::Marks::BaseMismatch)
      end

      # `drifted` is on the record and free to read, and a refusal that hides it
      # names a line holding content the human never pointed at.
      it "says the anchor drifted, rather than sending a human to a line they never pointed at" do
        adrift = annotation(kind: "blocker", line: 5, drifted: true)

        expect { policy.admit!("approve", changeset: subject_changeset, marks: reviewed, annotations: [adrift]) }
          .to raise_error(Lain::Review::Verdict::Policy::Blocked, /a\.rb:5 \(new, drifted\)/)
      end

      it "counts them, so two objections drifted onto one line do not read as one repeated" do
        both = [blocker, annotation(kind: "blocker", text: "and this one too")]

        expect { policy.admit!("approve", changeset: subject_changeset, marks: reviewed, annotations: both) }
          .to raise_error(Lain::Review::Verdict::Policy::Blocked, /2 blockers/)
      end

      it "caps how many blockers it names and says how many it did not, as the partial refusal does" do
        many = (1..20).map { |number| annotation(kind: "blocker", line: number) }

        expect { policy.admit!("approve", changeset: subject_changeset, marks: reviewed, annotations: many) }
          .to raise_error(Lain::Review::Verdict::Policy::Blocked) do |error|
            expect(error.message).to match(/\b#{20 - described_class::NAMED_LIMIT} more\b/)
          end
      end
    end
  end

  # WHAT `--permissive` ACTUALLY BUYS, and the distinction the flag's own
  # sentence draws. The refusal offers the flag as a way past ROWS nobody has
  # read; an unanswered blocker is not an unread row, it is somebody who read
  # the work and said no. So the typed escape skips Incomplete and keeps
  # Blocked, and `Permissive` -- which reads nothing at all -- stays where it
  # was, on the injected path with no way to type it.
  describe described_class::BlockersOnly do
    subject(:policy) { described_class.new }

    it "admits an approve over a changeset nobody has marked, which is what the flag is for" do
      expect { policy.admit!("approve", changeset: subject_changeset, marks: marked([]), annotations: []) }
        .not_to raise_error
    end

    # THE ONE THIS FLAG MUST NOT LET THROUGH. An escape that forgave an
    # objection would make `blocker` a kind nothing reads again, one layer up
    # from where it was already found to be exactly that.
    it "still refuses over an unanswered blocker, in the blocker's own words" do
      expect { policy.admit!("approve", changeset: subject_changeset, marks: marked([]), annotations: [blocker]) }
        .to raise_error(Lain::Review::Verdict::Policy::Blocked, /a\.rb:3/)
    end

    # Resolution is the SAME gesture the strict policy takes, because it is the
    # same rule read from one place: a later note at that position answers it.
    it "admits once a later note on that line has answered the blocker" do
      answered = [blocker, annotation(kind: "note", text: "answered: renamed in the follow-up")]

      expect { policy.admit!("approve", changeset: subject_changeset, marks: marked([]), annotations: answered) }
        .not_to raise_error
    end

    it "is a Policy, so a session wired with one is wired with the same duck" do
      expect(policy).to be_a(Lain::Review::Verdict::Policy)
    end

    # The flag resolves HERE and nowhere else, and the negative is the half that
    # matters: `Permissive` reads nothing, so resolving to it would hand a typed
    # line the power to forgive an objection.
    it "is what the flag resolves to, and Permissive is not" do
      resolved = Lain::Review::Verdict::Policy.strict_unless(permissive: true)

      expect(resolved).to be_an_instance_of(described_class)
      expect(resolved).not_to be_a(Lain::Review::Verdict::Policy::Permissive)
    end

    it "resolves to the strict rule when the flag was not typed" do
      expect(Lain::Review::Verdict::Policy.strict_unless(permissive: false))
        .to be_a(Lain::Review::Verdict::Policy::EveryHunk)
    end
  end

  describe described_class::Permissive do
    subject(:policy) { described_class.new }

    it "admits a verdict over a changeset nobody has reviewed at all" do
      expect { policy.admit!("approve", changeset: subject_changeset, marks: marked([]), annotations: []) }
        .not_to raise_error
    end

    # The escape stays an escape. A run with nobody at a keyboard cannot resolve
    # a blocker either, so a Permissive that started reading them would wedge
    # exactly the case it exists to unwedge.
    it "admits over an unresolved blocker too, because it reads none of its arguments" do
      expect { policy.admit!("approve", changeset: subject_changeset, marks: marked([]), annotations: [blocker]) }
        .not_to raise_error
    end

    it "is a Policy, so a session wired with one is wired with the same duck" do
      expect(policy).to be_a(Lain::Review::Verdict::Policy)
    end
  end

  describe Lain::Review::Verdict::None do
    it "is not nil, so no caller has to nil-check a verdict that has not been submitted" do
      expect(described_class).not_to be_nil
    end

    it "answers #empty? -- the ONE predicate a recorded verdict String answers too" do
      expect(described_class).to be_empty
      expect(Lain::Review::VERDICTS.first).not_to be_empty
    end

    it "renders as nothing at all, so an interpolating surface prints no placeholder" do
      expect("verdict: #{described_class}").to eq("verdict: ")
    end

    it "is not a member of the verdict vocabulary" do
      expect(Lain::Review::VERDICTS).not_to include(described_class)
    end
  end
end
