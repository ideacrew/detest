require "redis"
require "json"

module Detest
  module Adapters
    class RedisAdapter
      DEFAULT_ATTEMPT = 1

      attr_reader :redis, :attempt, :input_key, :failure_key, :result_key, :runner_key

      # session_key : stable for the whole CI run (e.g. "<run_id>_rspec").
      # attempt     : the CI run-attempt number (>= 1).
      #
      # Each attempt READS a frozen input set and WRITES to its own failure
      # set. The two are never the same key, so nothing a worker records can
      # re-enter the set its peers are draining.
      def initialize(session_key, attempt: DEFAULT_ATTEMPT, **redis_options)
        @redis       = Redis.new(**redis_options)
        @session_key = session_key
        @attempt     = Integer(attempt)

        # First attempt drains the freshly published work set; every later
        # attempt drains the immediately-preceding attempt's failures.
        @input_key   = @attempt <= 1 ? work_key : failure_key_for(@attempt - 1)
        @failure_key = failure_key_for(@attempt)
        @result_key  = "__#{@session_key}_tp_adapter_test_results_storage"
        @runner_key  = "__#{@session_key}_tp_adapter_runner_count_storage_attempt_#{@attempt}"
      end

      def close
        @redis.disconnect!
      end

      # Publisher-only: seed the first attempt's work set.
      def enqueue(list)
        return if list.nil? || list.empty?

        @redis.sadd(work_key, list)
      end

      # Atomically claim the next file for this attempt; nil when exhausted.
      # First-run and rerun use the same call — the input set was resolved at
      # construction time from the attempt number.
      def pop
        @redis.spop(@input_key)
      end
      alias fpop pop # retained for backward compatibility

      # Carry a still-failing file forward to the NEXT attempt. Writes to this
      # attempt's own failure set, which is never consumed during this attempt.
      def log_failure(spec_file)
        @redis.sadd(@failure_key, [spec_file])
      end

      def log_result(spec_file, result, props = {})
        logged_payload = props.merge({
          test: spec_file,
          passed: result
        })
        @redis.sadd(@result_key, JSON.dump(logged_payload))
      end

      # Liveness bookkeeping only — no longer gates any work distribution.
      def record_worker
        @redis.incr(@runner_key)
      end

      def end_worker
        @redis.decr(@runner_key)
      end

      private

      def work_key
        "__#{@session_key}_tp_adapter_test_storage"
      end

      def failure_key_for(attempt)
        "__#{@session_key}_tp_adapter_test_failure_storage_attempt_#{attempt}"
      end
    end
  end
end
