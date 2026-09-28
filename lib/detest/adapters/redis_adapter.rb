require "redis"
require "json"

module Detest
  module Adapters
    class RedisAdapter
      # Comfortably longer than a full CI run (GitHub Actions' own default job
      # timeout is 6h), short enough that a session's keys don't outlive the
      # run and accumulate in the shared Redis instance indefinitely.
      DEFAULT_KEY_TTL_SECONDS = 6 * 60 * 60

      attr_reader :redis, :redis_session_key, :redis_session_failure_key,
                  :redis_session_retry_key, :redis_session_runner_key,
                  :redis_session_result_key

      def initialize(session_key, *args, ttl: DEFAULT_KEY_TTL_SECONDS, **kwargs)
        @redis = Redis.new(*args, **kwargs)
        @ttl = ttl
        @redis_session_key = "__#{session_key}_tp_adapter_test_storage"
        @redis_session_failure_key = "__#{session_key}_tp_adapter_test_failure_storage"
        @redis_session_result_key = "__#{session_key}_tp_adapter_test_results_storage"
        @redis_session_runner_key = "__#{session_key}_tp_adapter_test_runner_count_storage"
        @redis_session_retry_key = "__#{session_key}_tp_adapter_test_retry_error_storage"
      end

      def close
        @redis.disconnect!
      end

      def record_worker(pipeline = redis)
        pipeline.incr(@redis_session_runner_key)
        pipeline.expire(@redis_session_runner_key, @ttl)
      end

      def end_worker(pipeline = redis)
        decr = pipeline.decr(@redis_session_runner_key)
        pipeline.expire(@redis_session_runner_key, @ttl)
        if decr < 1
          smem = pipeline.smembers(@redis_session_failure_key)
          smem.each do |smember|
            pipeline.smove(@redis_session_failure_key, @redis_session_retry_key, smember)
          end
          pipeline.expire(@redis_session_retry_key, @ttl) if smem.any?
        end
      end

      def enqueue(list)
        return if list.nil?
        return unless list.any?
        @redis.pipelined do |pipeline|
          pipeline.sadd(@redis_session_key, list)
          pipeline.expire(@redis_session_key, @ttl)
        end
      end

      def pop
        @redis.spop(@redis_session_key)
      end

      def log_failure(spec_file)
        @redis.pipelined do |pipeline|
          pipeline.sadd(@redis_session_failure_key, [spec_file])
          pipeline.expire(@redis_session_failure_key, @ttl)
        end
      end

      def log_result(spec_file, result, props = {})
        logged_payload = props.merge({
          test: spec_file,
          passed: result
        })
        @redis.pipelined do |pipeline|
          pipeline.sadd(@redis_session_result_key, JSON.dump(logged_payload))
          pipeline.expire(@redis_session_result_key, @ttl)
        end
      end

      def fpop
        @redis.spop(@redis_session_retry_key)
      end
    end
  end
end