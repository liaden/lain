# frozen_string_literal: true

module Lain
  module Shell
    # What a command the verdict leaves to a shell means, read only where a
    # shell could not read it another way: plain words, single quotes, double
    # quotes holding nothing a shell interprets, each stage followed only by
    # `2>&1` or a /dev/null discard, joined by `|`, `&&` and `;`, after any
    # number of `cd`s to one literal directory each. Inside double quotes
    # a backslash before anything but `$`, a backquote, `"`, `\` or a newline
    # is kept as written, so grep's `\|` reads as bash passes it.
    #
    # {Verdict} abstains on all of this, and an approving rule that reads the
    # term here still hands the backend the model's string: the call runs
    # through `sh -c`, so this refuses anything a shell would read otherwise.
    class Reading
      KINDS = %w[program list pipeline command command_name word number concatenation raw_string string
                 file_redirect redirected_statement].freeze
      # Spelled out whole: `&>` is bash's, and a dash `sh` reads `cmd &>/dev/null`
      # as "background cmd, then truncate /dev/null".
      REDIRECTS = ["2>&1", "2>#{File::NULL}", ">#{File::NULL}"].freeze
      SPAN = /'([^'\0]*)'|"((?:[^"$`\\!\0]|\\[^"$`\\!\0\n])*)"|([^'"\\$`{}*?\[\]!\0\s]+)/
      WORD = /\A(?:#{SPAN})+\z/
      # bash expands a tilde at a word's start, and after `=` or `:` in a word
      # it takes for an assignment.
      TILDE = /(?:\A|[=:])~/
      PIPE = "|"
      AND = "&&"
      THEN = ";"
      CD = "cd"
      DASH = "-"
      SEPARATOR = "/"

      # @param command [Object] as the model sent it
      # @param cwd [String, nil] the call's own
      # @return [Array(Term, String), nil] the term and the cwd its stages run
      #   in, the call's own when no `cd` moved it, or nil for a command this
      #   cannot read for certain
      def self.of(command, cwd) = command.is_a?(String) ? from(Parse.new.call(command), cwd) : nil

      # @param result [Parse::Result] a parse a caller already holds
      # @param cwd [String, nil] the call's own
      # @return [Array(Term, String), nil] as for {.of}
      def self.from(result, cwd)
        argvs = result.stages.map { |stage| words(stage.argv) } if literal?(result)
        new(argvs, joins(result), cwd).read if argvs&.all?
      end

      def self.literal?(result)
        result.covered? && !result.broken? && (result.kinds - KINDS).empty? &&
          result.separators.all? { [PIPE, AND, THEN].include?(_1.text) } &&
          result.stages.size == result.separators.size + 1 &&
          result.redirects_placed? { |redirect, _| REDIRECTS.include?(redirect.text) }
      end

      def self.joins(result) = result.separators.sort_by { _1.byte_range.begin }.map(&:text)

      def self.words(argv)
        texts = argv.map { |raw| text(raw) }
        texts if texts.all?
      end

      def self.text(raw)
        return unless raw.match?(WORD) && !raw.match?(TILDE)

        text = raw.scan(SPAN).map { |single, double, bare| single || double || bare }.join
        text unless text.empty?
      end
      private_class_method :literal?, :joins, :words, :text

      def initialize(argvs, joins, cwd)
        @moves = argvs.take_while { _1.first == CD }
        @stages = argvs.drop(@moves.size).zip([nil, *joins.drop(@moves.size)])
        @leading = joins.first(@moves.size)
        @joins = joins
        @cwd = cwd
      end

      # A `cd` past the leading ones is a builtin no argv can run. {#moved}
      # applies a move to every stage, while `sh` runs a stage after `;` in the
      # original cwd when the `cd` failed, so a move refuses `;` anywhere.
      def read
        [term, moved] if @stages.any? && @moves.all? { cd?(_1) } && @leading.all?(AND) &&
                         @stages.none? { |argv, _| argv.first == CD } && (@moves.empty? || @joins.none?(THEN))
      end

      private

      def cd?(argv) = argv.size == 2 && !argv.last.start_with?(DASH)

      def term
        pipelines = @stages.slice_before { |_, join| [AND, THEN].include?(join) }.map do |group|
          Term::Pipeline.new(stages: group.map { |argv, _| Term::Stage.new(argv:, discards: []) })
        end
        Term.new(pipelines:)
      end

      def moved
        return @cwd if @moves.empty?

        @moves.map(&:last).inject(@cwd || ".") { |at, to| to.start_with?(SEPARATOR) ? to : File.join(at, to) }
      end
    end
  end
end
