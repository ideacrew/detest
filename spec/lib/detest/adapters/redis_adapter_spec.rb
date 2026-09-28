require "spec_helper"
require "securerandom"

describe Detest::Adapters::RedisAdapter, "when a runner is recorded" do
  let(:session_key) { "TESTING SESSION KEY"}

  subject { described_class.new(session_key) }

  let(:redis) { subject.redis }

  it "adds to the number of runners" do
    rc_1 = nil
    rc_2 = nil
    redis.multi do |pipeline|
      rc_1 = pipeline.get(subject.redis_session_runner_key)
      subject.record_worker(pipeline)
      rc_2 = pipeline.get(subject.redis_session_runner_key)
    end
    expect(rc_2.value.to_i).to eql((rc_1.value || "0").to_i + 1)
  end
end

describe Detest::Adapters::RedisAdapter, "key expiration" do
  # A fresh session key per example so runs don't stomp on each other or on
  # whatever a previous run left behind.
  let(:session_key) { "TTL SPEC SESSION #{SecureRandom.hex(4)}" }

  subject { described_class.new(session_key, ttl: ttl) }

  let(:ttl) { 60 }
  let(:redis) { subject.redis }

  after do
    redis.del(
      subject.redis_session_key,
      subject.redis_session_failure_key,
      subject.redis_session_retry_key,
      subject.redis_session_runner_key,
      subject.redis_session_result_key,
      subject.redis_session_finalized_key
    )
  end

  it "defaults to a TTL that outlasts GitHub Actions' rerun window" do
    default_adapter = described_class.new("#{session_key}-default")
    default_adapter.enqueue(["a_spec.rb"])
    expect(default_adapter.redis.ttl(default_adapter.redis_session_key))
      .to be_within(5).of(described_class::DEFAULT_KEY_TTL_SECONDS)
    expect(described_class::DEFAULT_KEY_TTL_SECONDS)
      .to be > described_class::GITHUB_RERUN_WINDOW_DAYS * 24 * 60 * 60
    default_adapter.redis.del(default_adapter.redis_session_key)
  end

  it "coerces a string ttl (e.g. from an env var) to an integer" do
    adapter = described_class.new("#{session_key}-string-ttl", ttl: "60")
    adapter.enqueue(["a_spec.rb"])
    expect(adapter.redis.ttl(adapter.redis_session_key)).to be_between(1, 60)
    adapter.redis.del(adapter.redis_session_key)
  end

  it "raises immediately for a ttl that can't be coerced to an integer" do
    expect { described_class.new(session_key, ttl: "not-a-number") }.to raise_error(ArgumentError)
  end

  it "sets a TTL on the work set when enqueueing" do
    subject.enqueue(["a_spec.rb", "b_spec.rb"])
    expect(redis.ttl(subject.redis_session_key)).to be_between(1, ttl)
  end

  it "sets a TTL on the failure set when logging a failure" do
    subject.log_failure("a_spec.rb")
    expect(redis.ttl(subject.redis_session_failure_key)).to be_between(1, ttl)
  end

  it "sets a TTL on the result set when logging a result" do
    subject.log_result("a_spec.rb", true)
    expect(redis.ttl(subject.redis_session_result_key)).to be_between(1, ttl)
  end

  it "sets a TTL on the runner count when recording a worker" do
    subject.record_worker
    expect(redis.ttl(subject.redis_session_runner_key)).to be_between(1, ttl)
  end

  it "sets a TTL on the runner count when ending a worker" do
    subject.record_worker
    subject.end_worker
    expect(redis.ttl(subject.redis_session_runner_key)).to be_between(1, ttl)
  end

  it "sets a TTL on the retry set when failures are carried over on the last worker" do
    subject.record_worker
    subject.log_failure("a_spec.rb")
    subject.end_worker
    expect(redis.ttl(subject.redis_session_retry_key)).to be_between(1, ttl)
  end

  it "sets a TTL on the finalized marker when the last worker ends" do
    subject.record_worker
    subject.end_worker
    expect(redis.ttl(subject.redis_session_finalized_key)).to be_between(1, ttl)
  end
end

describe Detest::Adapters::RedisAdapter, "rerun safety (fpop)" do
  let(:session_key) { "FPOP SPEC SESSION #{SecureRandom.hex(4)}" }

  subject { described_class.new(session_key, ttl: 60) }

  let(:redis) { subject.redis }

  after do
    redis.del(
      subject.redis_session_key,
      subject.redis_session_failure_key,
      subject.redis_session_retry_key,
      subject.redis_session_runner_key,
      subject.redis_session_result_key,
      subject.redis_session_finalized_key
    )
  end

  it "raises instead of silently returning nil when the session was never finalized" do
    expect { subject.fpop }.to raise_error(Detest::Adapters::RedisAdapter::MissingRetryQueueError)
  end

  it "raises instead of silently returning nil when the finalized marker expired" do
    subject.record_worker
    subject.end_worker
    redis.del(subject.redis_session_finalized_key) # simulate TTL expiry
    expect { subject.fpop }.to raise_error(Detest::Adapters::RedisAdapter::MissingRetryQueueError)
  end

  it "returns nil, not an error, when the session finalized with zero failures" do
    subject.record_worker
    subject.end_worker
    expect(subject.fpop).to be_nil
  end

  it "pops a real failure once the session is finalized" do
    subject.record_worker
    subject.log_failure("a_spec.rb")
    subject.end_worker
    expect(subject.fpop).to eq("a_spec.rb")
    expect(subject.fpop).to be_nil
  end
end