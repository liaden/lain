# frozen_string_literal: true

require "json"

module Lain
  module Review
    class Prefill
      # The FILE: what a critique writes beside its prose, and how it is read
      # back. Separate from {Prefill} because they answer different questions --
      # this one owns a wire format (where the file goes, what a line may say,
      # and what happens to a line that cannot be read), while {Prefill} owns the
      # findings once they are values and what the human did to them.
      #
      # Every refusal here is a {Prefill::Malformed} naming the LINE NUMBER.
      # Nothing is skipped and nothing is repaired: a finding dropped in silence
      # is one the human never gets to disagree with, and every count still looks
      # right afterwards (`gh/init.lua:170-182`, the defect octo shipped).
      module Sidecar
        # The suffix that replaces the prose's own extension. See {.beside}.
        SUFFIX = ".findings.jsonl"

        # The side a finding is about when it does not say. A critique reviews
        # the change as it now stands, so silence means the new side; a finding
        # about a line the change DELETED says `old` explicitly.
        DEFAULT_SIDE = "new"

        class << self
          # Where a critique's sidecar goes: beside the prose, under the prose's
          # own name with {SUFFIX} in place of its extension, so the pair is
          # obvious in a directory listing and neither file has to name the other.
          #
          # @param prose [String] the critique's own path
          # @return [String]
          # @raise [Anchor::InvalidField] for a path that names nothing
          def beside(prose)
            # Refused by name, like every other entry point here: a nil prose
            # path would otherwise answer a bare ".findings.jsonl", which is a
            # real relative path and would be written.
            path = Anchor.nonblank_string!(prose, field: "the critique's own path")
            # `delete_suffix`, never `sub`: the extension is a SUFFIX, and a
            # pattern would eat the first `.md` it found -- `docs.md/critique.md`
            # would become `docs/critique.findings.jsonl`, in another directory.
            -"#{path.delete_suffix(File.extname(path))}#{SUFFIX}"
          end

          # @param sidecar [String] NDJSON
          # @return [Array<Finding>] in the order they were written
          # @raise [Prefill::Malformed]
          def read(sidecar)
            numbered = sidecar.each_line.with_index(1).map { |source, number| [number, parse(source, number)] }
            unique!(numbered)
            numbered.map(&:last)
          end

          private

          def parse(source, number) = finding!(fields!(source, number), number)

          # The line as a JSON object, or a refusal naming the line number. A
          # blank line is not JSON and is refused like any other unreadable line:
          # a sidecar is written by a machine, so there is no such thing as a
          # spacer.
          def fields!(source, number)
            fields = JSON.parse(source)
            return fields if fields.is_a?(Hash)

            raise Prefill::Malformed, "sidecar line #{number} is a #{fields.class}, not a finding object -- " \
                                      "one JSON object per line, no blank lines and no prose"
          rescue JSON::ParserError => e
            raise Prefill::Malformed, "sidecar line #{number} is not JSON " \
                                      "(#{e.message.lines.first.strip}) -- one JSON object per line, " \
                                      "no blank lines and no prose"
          end

          def finding!(fields, number)
            Finding.new(path: fields["path"], side: fields.fetch("side", DEFAULT_SIDE),
                        line: fields["line"], rank: fields["rank"], text: fields["text"])
          rescue Error => e
            raise Prefill::Malformed, "sidecar line #{number} cannot be read as a finding: #{e.message}"
          end

          # The one refusal a file can make that {Prefill.index} cannot: both
          # line numbers. In a long sidecar the two copies are identical
          # sentences, so "repeated" alone leaves the human grepping for the
          # difference between them.
          def unique!(numbered)
            numbered.each_with_object({}) do |(number, finding), seen|
              Prefill.repeated!(finding, seen[finding.id], number) unless seen[finding.id].nil?
              seen[finding.id] = number
            end
          end
        end
      end
    end
  end
end
