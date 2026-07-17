require 'detest'

adapter = Detest::Adapters::RedisAdapter.new(
  "frank",
  attempt: Integer(ENV.fetch("DETEST_RUN_ATTEMPT", 1))
)

client = Detest::Workers::RspecWorker.boot(ARGV)
client.run(adapter)