# frozen_string_literal: true

require "json"
require "fileutils"
require "net/http"
require "time"
require "yaml"

module E2E
  # A journey's model turns, recorded once from a real local ollama and replayed to the real binary
  # through {Upstream}. Only `/api/chat` lives in a journey's cassette; the probes live in one shared
  # file, because how many times `lain` probes varies from run to run.
  module Cassette
    DIR = File.expand_path("../../fixtures/vcr_cassettes/e2e", __dir__)

    # Per-run timestamps in a reply, which a committed cassette has no use for.
    TIMESTAMPS = /"(expires_at|created_at)":"[^"]*"/
    TIMESTAMP_PLACEHOLDER = "<RECORDED>"

    class Missing < StandardError; end
    class Stale < StandardError; end
    class Unrecorded < StandardError; end

    def self.for(name)
      path = File.join(DIR, "#{name}.yml")
      return Replay.load(path) if File.exist?(path)
      raise Missing, "no cassette at #{relative(path)}; record it with: #{re_record(path)}" unless recording?

      Recorder.new(path)
    end

    def self.probes = Probes.new(File.join(DIR, "probes.yml"), recording: recording?)

    # A drift that stalls the chat first surfaces as a wait timing out. Failing the cassette on the
    # way out turns it into the Stale that names the field and the fix, with the timeout as its cause.
    def self.serve(name)
      cassette = self.for(name)
      upstream = Upstream.start(cassette, probes:)
      result = begin
        yield upstream, cassette
      rescue StandardError => e
        cassette.fail(e)
      end
      cassette.finish
      result
    ensure
      upstream&.stop
    end

    def self.recording? = VcrRecording.provider == :ollama

    def self.relative(path) = path.delete_prefix("#{File.expand_path("../../..", __dir__)}/")

    def self.re_record(path)
      journey = RSpec.current_example&.file_path&.delete_prefix("./") || "spec/e2e/<journey>_spec.rb"
      "rm -f #{relative(path)} && LAIN_SPEC_BUDGET=900 LAIN_RECORD=ollama bundle exec rspec #{journey}"
    end

    # The parts of a request its reply depends on. The system prompt is left out on purpose, so a
    # prompt edit does not stale every cassette.
    Fingerprint = Data.define(:model, :tools, :option_keys, :last_message) do
      def self.of(body)
        last = body.fetch("messages", []).last || {}
        new(model: body["model"], tools: body.fetch("tools", []).map { |tool| tool.dig("function", "name") }.sort,
            option_keys: body.fetch("options", {}).keys.sort, last_message: last.values_at("role", "content"))
      end

      def self.from(hash) = new(**hash.transform_keys(&:to_sym))

      def differences(other) = members.reject { |member| public_send(member) == other.public_send(member) }
    end

    # One recorded round trip, in the YAML shape VCR 6 writes. A chat's request is kept as its
    # Fingerprint rather than its body: the body is mostly system prompt and tool schemas, which
    # replay never matches on and which would churn the file on every prompt edit.
    Interaction = Data.define(:verb, :path, :request, :status, :message, :response, :recorded_at) do
      def self.from(hash)
        sent = hash.dig("request", "body", "string").to_s
        new(verb: hash.dig("request", "method"), path: URI(hash.dig("request", "uri")).path,
            request: sent.empty? ? {} : JSON.parse(sent), status: hash.dig("response", "status", "code"),
            message: hash.dig("response", "status", "message"), response: hash.dig("response", "body", "string"),
            recorded_at: hash["recorded_at"])
      end

      def fingerprint = Fingerprint.from(request)

      def sent = request.empty? ? "" : JSON.generate(request)

      def reply = Upstream::Reply.new(status:, lines: response.lines)

      def to_vcr
        { "request" => { "method" => verb, "uri" => "#{OLLAMA_API_BASE}#{path}",
                         "body" => { "encoding" => "UTF-8", "string" => sent } },
          "response" => { "status" => { "code" => status, "message" => message },
                          "body" => { "encoding" => "UTF-8", "string" => response } },
          "recorded_at" => recorded_at }
      end
    end

    module Tape
      def self.read(path) = YAML.safe_load_file(path).fetch("http_interactions").map { |hash| Interaction.from(hash) }

      def self.write(path, interactions)
        FileUtils.mkdir_p(File.dirname(path))
        yaml = YAML.dump("http_interactions" => interactions.map(&:to_vcr), "recorded_with" => "VCR 6.4.0")
        File.write("#{path}.tmp", yaml)
        File.rename("#{path}.tmp", path)
      end
    end

    # The real ollama, reached from the spec process. Holding the port is what lets the request past
    # WebMock, and what makes OllamaProbeStub stand aside for a probe.
    module Ollama
      def self.forward(verb, path, body: nil, kept: body.to_h)
        uri = URI("#{OLLAMA_API_BASE}#{path}")
        response = NetworkAccess.permit_loopback(uri.port) do
          Net::HTTP.start(uri.host, uri.port, read_timeout: 600) do |http|
            http.send_request(verb.upcase, path, body && JSON.generate(body), "Content-Type" => "application/json")
          end
        end
        Interaction.new(verb:, path:, request: kept, status: response.code.to_i, message: response.message,
                        response: scrub(response.body), recorded_at: Time.now.utc.httpdate)
      end

      def self.scrub(text)
        CassetteHygiene.redact(String.new(text.to_s, encoding: Encoding::UTF_8))
                       .gsub(TIMESTAMPS) { "\"#{Regexp.last_match(1)}\":\"#{TIMESTAMP_PLACEHOLDER}\"" }
      end
    end

    # Answers `/api/chat` in recorded order. A raise inside the stand-in's thread never reaches the
    # journey, so every drift is collected here for {#finish} to report once the journey is over.
    class Replay
      def self.load(path) = new(Tape.read(path), how: Cassette.re_record(path))

      attr_reader :how

      def initialize(interactions, how:)
        @interactions = interactions
        @how = how
        @played = 0
        @mismatches = []
        @lock = Mutex.new
      end

      def call(request)
        @lock.synchronize do
          interaction = @interactions[@played]
          return refuse(request) if interaction.nil? || request.path != interaction.path

          note(interaction.fingerprint, Fingerprint.of(request.body || {}))
          @played += 1
          interaction.reply
        end
      end

      def mismatches = @lock.synchronize { @mismatches.dup }

      def unplayed
        @lock.synchronize do
          @interactions.drop(@played).each_with_index.map do |interaction, offset|
            { index: @played + offset, fingerprint: interaction.fingerprint }
          end
        end
      end

      def fail(error)
        finish
        raise error
      end

      def finish
        return if problems.empty?

        raise Stale, "the cassette no longer matches the journey:\n  #{problems.join("\n  ")}\nre-record: #{how}"
      end

      private

      def note(recorded, sent)
        recorded.differences(sent).each do |field|
          @mismatches << { index: @played, field:, recorded: recorded.public_send(field),
                           sent: sent.public_send(field) }
        end
      end

      def refuse(request)
        recorded = @interactions[@played]&.path || "nothing: the cassette is exhausted"
        @mismatches << { index: @played, field: :path, recorded:, sent: "#{request.verb} #{request.path}" }
        Upstream::Reply.new(status: 500, lines: [JSON.generate("error" => "not in the cassette")])
      end

      def problems
        mismatches.map { |mismatch| "request #{mismatch[:index]}: #{drift(mismatch)}" } +
          unplayed.map { |entry| "recorded call #{entry[:index]} was never asked for" }
      end

      def drift(mismatch)
        recorded, sent = mismatch.values_at(:recorded, :sent)
        return "#{mismatch[:field]} was #{recorded.inspect}, now #{sent.inspect}" unless mismatch[:field] == :tools

        "tools gained #{(sent - recorded).inspect} and lost #{(recorded - sent).inspect}"
      end
    end

    class Recorder
      def initialize(path)
        @path = path
        @interactions = []
        @lock = Mutex.new
      end

      # The slot is taken on arrival, because replay answers in arrival order and two concurrent
      # calls can finish the other way round.
      def call(request)
        slot = @lock.synchronize { @interactions.push(nil).size - 1 }
        interaction = Ollama.forward("post", request.path, body: request.body,
                                                           kept: Fingerprint.of(request.body).to_h)
        @lock.synchronize { @interactions[slot] = interaction }
        interaction.reply
      end

      def mismatches = []

      def unplayed = []

      def save
        @lock.synchronize do
          raise Unrecorded, "a forward never returned; nothing written to #{@path}" if @interactions.include?(nil)

          Tape.write(@path, @interactions)
        end
      end

      alias finish save

      # A partial recording would replay as Stale where the truth is Missing, so nothing is written.
      def fail(_error) = raise(Unrecorded, "the recording failed; nothing written to #{@path}")
    end

    # The status probes, one `/api/ps` and one `/api/show` per model, recorded the first time a
    # journey asks for one and answered from the file every time after.
    class Probes
      VERBS = { "/api/ps" => "get", "/api/show" => "post" }.freeze

      def initialize(path, recording:)
        @path = path
        @recording = recording
        @lock = Mutex.new
        @interactions = File.exist?(path) ? Tape.read(path) : []
      end

      # nil hands the request on to the journey's handler, which reports it as not in the cassette.
      def call(request)
        return unless VERBS.key?(request.path)

        @lock.synchronize { (recorded(request) || record(request))&.reply }
      end

      private

      def recorded(request) = @interactions.find { |found| found.path == request.path && found.request == key(request) }

      def key(request) = request.path == "/api/show" ? { "model" => request.body.to_h["model"] } : {}

      def record(request)
        return unless @recording

        found = Ollama.forward(VERBS.fetch(request.path), request.path, body: key(request).presence)
        raise "ollama answered #{request.path} #{key(request)} with #{found.status}" unless found.status == 200

        @interactions << found
        Tape.write(@path, @interactions)
        found
      end
    end
  end
end
