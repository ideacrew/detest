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
      subject.redis_session_runner_key
    )
  end

  it "defaults to a 6 hour TTL when none is given" do
    default_adapter = described_class.new("#{session_key}-default")
    default_adapter.enqueue(["a_spec.rb"])
    expect(default_adapter.redis.ttl(default_adapter.redis_session_key))
      .to be_within(5).of(described_class::DEFAULT_KEY_TTL_SECONDS)
    default_adapter.redis.del(default_adapter.redis_session_key)
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
end