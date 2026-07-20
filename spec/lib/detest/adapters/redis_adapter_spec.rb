require "spec_helper"

describe Detest::Adapters::RedisAdapter, "when a runner is recorded" do
  let(:session_key) { "TESTING SESSION KEY" }

  subject { described_class.new(session_key) }

  let(:redis) { subject.redis }

  it "adds to the number of runners" do
    before_count = redis.get(subject.runner_key).to_i
    subject.record_worker
    after_count = redis.get(subject.runner_key).to_i
    expect(after_count).to eql(before_count + 1)
  end
end

describe Detest::Adapters::RedisAdapter, "input/failure set selection by attempt" do
  let(:session_key) { "TESTING SESSION KEY ATTEMPTS" }

  context "on the first attempt" do
    subject { described_class.new(session_key, attempt: 1) }

    it "drains the published work set" do
      expect(subject.input_key).to eql("__#{session_key}_tp_adapter_test_storage")
    end

    it "logs failures to a set that is not the one it drains" do
      expect(subject.failure_key).not_to eql(subject.input_key)
    end
  end

  context "on a later attempt" do
    subject { described_class.new(session_key, attempt: 3) }

    it "drains the previous attempt's failure set" do
      expect(subject.input_key)
        .to eql("__#{session_key}_tp_adapter_test_failure_storage_attempt_2")
    end

    it "writes failures to this attempt's own set, never the one it drains" do
      expect(subject.failure_key)
        .to eql("__#{session_key}_tp_adapter_test_failure_storage_attempt_3")
      expect(subject.failure_key).not_to eql(subject.input_key)
    end
  end

  it "coerces a string attempt (as passed from the CI env) to an integer" do
    adapter = described_class.new(session_key, attempt: "4")
    expect(adapter.attempt).to eql(4)
    expect(adapter.input_key)
      .to eql("__#{session_key}_tp_adapter_test_failure_storage_attempt_3")
  end
end
