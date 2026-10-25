# frozen_string_literal: true

require "json"

RSpec.describe Lain::Gateway::Inspection do
  let(:secret) { "s3cr3t-value-0123456789" }
  let(:inspection) { inspecting(secret) }

  def inspecting(value)
    described_class.new(literals: Lain::Sensitivity::Secrets.for(
      child_env: Lain::Exec::ChildEnv.from({ "API_SECRET" => value }), context: nil
    ))
  end

  def body(**fields) = JSON.generate({ model: "glm-5.3:cloud", stream: false, **fields })

  def asking(content) = body(messages: [{ role: "user", content: }])

  it "refuses a body carrying a known secret, naming a known secret and never the value" do
    verdict = inspection.call(asking("the key is #{secret}"))

    expect(verdict).to have_attributes(refuse: true, reason: a_string_including("known secret"))
    expect(verdict.reason).not_to include(secret)
  end

  it "refuses a secret written as a JSON number, which no decoded string holds" do
    verdict = inspecting("12345678901234").call(%({"model":"m","stream":false,"pin":12345678901234}))

    expect(verdict).to have_attributes(refuse: true, reason: a_string_including("known secret"))
  end

  it "refuses a secret spelled in \\u escapes, which the raw bytes do not hold" do
    escaped = secret.chars.map { format("\\u%04x", _1.ord) }.join

    expect(inspection.call(%({"model":"m","stream":false,"content":"#{escaped}"})).refuse).to be(true)
  end

  it "refuses the base64 and the hex spelling of a known secret" do
    base64 = [secret].pack("m0")
    spellings = [base64, base64.delete("="), secret.unpack1("H*"), secret.unpack1("H*").upcase]

    expect(spellings.map { inspection.call(asking("value: #{_1}")).refuse }).to eq([true, true, true, true])
  end

  it "refuses a streaming body, naming non-streaming only" do
    verdict = inspection.call(body(stream: true, messages: []))

    expect(verdict).to have_attributes(refuse: true, reason: a_string_including("non-streaming only"))
  end

  %w[Stream STREAM ſtream].each do |spelling|
    it "refuses a second #{spelling} key, which a Go decoder reads as stream" do
      verdict = inspection.call(%({"model":"m","stream":false,"#{spelling}":true}))

      expect(verdict).to have_attributes(refuse: true, reason: a_string_including("non-streaming only"))
    end
  end

  it "refuses a null stream, on which ollama streams" do
    verdict = inspection.call(%({"model":"m","stream":null}))

    expect(verdict).to have_attributes(refuse: true, reason: a_string_including("non-streaming only"))
  end

  it "refuses a body that repeats the stream key" do
    expect(inspection.call(%({"model":"m","stream":false,"stream":true})).refuse).to be(true)
  end

  it "refuses a repeated key, which would hide the escaped secret its first value holds" do
    escaped = secret.chars.map { format("\\u%04x", _1.ord) }.join

    expect(inspection.call(%({"model":"m","stream":false,"content":"#{escaped}","content":"x"})).refuse).to be(true)
  end

  it "answers a verdict for a key that is not valid UTF-8" do
    expect(inspection.call(%({"model":"m","stream":false,"\xffStream":true}).b)).to be_a(described_class::Verdict)
  end

  it "refuses a body whose bytes are invalid in their own encoding as not a JSON object" do
    verdict = inspection.call(String.new(%({"model":"m","stream":false,"a":"\xff"}), encoding: Encoding::Shift_JIS))

    expect(verdict).to have_attributes(refuse: true, reason: a_string_including("not a JSON object"))
  end

  it "refuses an array body as not a JSON object" do
    expect(inspection.call("[]")).to have_attributes(refuse: true, reason: a_string_including("not a JSON object"))
  end

  it "reads a body of exactly the size limit and refuses one byte more" do
    padding = described_class::MAX_BYTES - asking("").bytesize
    at_limit = asking("x" * padding)

    expect(inspection.call(at_limit).refuse).to be(false)
    expect(inspection.call(asking("x" * (padding + 1))))
      .to have_attributes(refuse: true, reason: a_string_including("over #{described_class::MAX_BYTES} bytes"))
  end

  it "passes a non-streaming body that carries no known secret" do
    verdict = inspection.call(asking("is config/app.yml sensitive?"))

    expect(verdict).to have_attributes(refuse: false, flagged: [])
  end

  it "flags a shaped credential it does not refuse, naming its shape and not its value" do
    verdict = inspection.call(asking("is AKIAIOSFODNN7EXAMPLE a key?"))

    expect(verdict).to have_attributes(refuse: false, flagged: ["aws access key id"])
  end
end
