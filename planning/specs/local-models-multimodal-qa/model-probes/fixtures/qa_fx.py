ITEMS = [
 {"id": "q1_cart_empty", "truth": "pass",
  "ac": "Given an empty cart, When the client POSTs /checkout, Then the response is 422 with body {\"error\":\"cart_empty\"}.",
  "code": """def create
  return render(json: { error: "cart_empty" }, status: 422) if cart.items.empty?
  order = Checkout.new(cart).call
  render json: order, status: 201
end""",
  "output": """$ curl -s -o /dev/stderr -w '%{http_code}\\n' -X POST localhost:3000/checkout -b 'cart=empty'
{"error":"cart_empty"}
422"""},
 {"id": "q2_pw_len", "truth": "fail",
  "ac": "Passwords shorter than 12 characters are rejected; passwords of 12 or more characters are accepted.",
  "code": """class PasswordPolicy
  MIN = 12
  def acceptable?(pw) = pw.length > MIN
end""",
  "output": """$ bundle exec rspec spec/password_policy_spec.rb --format doc
PasswordPolicy
  rejects an 11-character password
  accepts a 20-character password
2 examples, 0 failures"""},
 {"id": "q3_timeout", "truth": "pass",
  "ac": "An upstream request that takes longer than 30 seconds is abandoned and logged as a timeout.",
  "code": """HTTP = Faraday.new(url: UPSTREAM) { |f| f.options.timeout = 30 }
def fetch(path)
  HTTP.get(path)
rescue Faraday::TimeoutError => e
  logger.warn("upstream timeout after 30s: #{path}")
  raise
end""",
  "output": """$ ruby script/slow_upstream_probe.rb --delay 45
W, [2026-09-20T10:02:31] WARN -- : upstream timeout after 30s: /reports/big
Faraday::TimeoutError (Net::ReadTimeout with #<TCPSocket:(closed)>)
elapsed: 30.04s"""},
 {"id": "q4_reqid_log", "truth": "fail",
  "ac": "Every completed request writes one log line that includes the request id.",
  "code": """after_action do
  line = "completed #{response.status} in #{elapsed_ms}ms"
  line += " request_id=#{request.request_id}" if response.status >= 400
  logger.info(line)
end""",
  "output": """$ curl -s -H 'X-Request-Id: abc123' localhost:3000/health >/dev/null; tail -1 log/development.log
I, [2026-09-20T10:05:12] INFO -- : completed 200 in 3ms"""},
 {"id": "q5_sort_ok", "truth": "pass",
  "ac": "`lain sessions` lists sessions newest first.",
  "code": """def sessions = store.all.sort_by(&:started_at).reverse""",
  "output": """$ lain sessions
2026-09-21 18:40  a1f3  fix flaky spec
2026-09-21 09:12  77c0  plan review
2026-09-19 22:05  0be9  qa round 18
2026-09-18 14:30  c4d2  bench arms"""},
 {"id": "q6_sort_bad", "truth": "fail",
  "ac": "`lain runs` lists runs newest first.",
  "code": """def runs = store.all.sort_by { |r| r.started_at.strftime("%d %H:%M") }.reverse""",
  "output": """$ lain runs
2026-08-30 18:40  e1a0  nightly
2026-09-21 09:12  93b1  nightly
2026-09-11 22:05  5d7e  manual
2026-09-09 14:30  2af8  nightly"""},
 {"id": "q7_exit_codes", "truth": "pass",
  "ac": "`lint` exits 0 when every file is clean and 1 when any file has an offense.",
  "code": """def run(files)
  offenses = files.flat_map { |f| check(f) }
  offenses.each { |o| report(o) }
  exit(offenses.empty? ? 0 : 1)
end""",
  "output": """$ lint fixtures/clean/*.rb; echo "status=$?"
status=0
$ lint fixtures/dirty/a.rb fixtures/clean/b.rb; echo "status=$?"
fixtures/dirty/a.rb:3: trailing whitespace
status=1"""},
 {"id": "q8_quiet", "truth": "fail",
  "ac": "With --quiet, `lint` prints nothing at all when every file is clean.",
  "code": """def run(files)
  offenses = files.flat_map { |f| check(f) }
  offenses.each { |o| report(o) } unless options[:quiet] && offenses.empty?
  summary(files.size) unless options[:quiet] && offenses.any?
  exit(offenses.empty? ? 0 : 1)
end""",
  "output": """$ lint --quiet fixtures/clean/*.rb; echo "status=$?"
3 files inspected, no offenses
status=0"""},
]

PROMPT = """You are a QA verifier. Decide whether the acceptance criterion below is satisfied, using ONLY the code excerpt and the captured command/test output. Be strict: "pass" means the evidence shows the criterion holds; "fail" means the evidence shows it is violated; "unsure" means the evidence cannot decide.

Acceptance criterion:
{ac}

Code excerpt:
```ruby
{code}
```

Captured output:
```
{output}
```

Answer with ONLY a JSON object: {{"verdict": "pass|fail|unsure", "evidence": "<one or two sentences>"}}"""


def prompt(it):
    return PROMPT.format(**it)
