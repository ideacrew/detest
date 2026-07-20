require 'detest'

adapter = Detest::Adapters::RedisAdapter.new(
  "cucumber-frank",
  attempt: Integer(ENV.fetch("DETEST_RUN_ATTEMPT", 1))
)

Detest::Workers::CucumberWorker.run!(adapter, ARGV)