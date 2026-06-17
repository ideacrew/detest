require "redis"
require "json"

module Detest
  module Adapters
    class RedisAdapter
      attr_reader :redis, :redis_session_key, :redis_session_failure_key,
                  :redis_session_retry_key, :redis_session_runner_key

      DEFAULT_RESILIENCY_OPTIONS = {
        connect_timeout: 3,
        read_timeout: 5,
        write_timeout: 5,
        reconnect_attempts: [0.25, 0.5, 1, 2]
      }.freeze

      def initialize(session_key, *args, **kwargs)
        @redis = Redis.new(*args, **DEFAULT_RESILIENCY_OPTIONS.merge(kwargs))
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
      end

      def end_worker(pipeline = redis)
        decr = pipeline.decr(@redis_session_runner_key)
        if decr < 1
          smem = pipeline.smembers(@redis_session_failure_key)
          smem.each do |smember|
            pipeline.smove(@redis_session_failure_key, @redis_session_retry_key, smember)
          end
        end
      end

      def enqueue(list)
        return if list.nil?
        return unless list.any?
        @redis.sadd(@redis_session_key, list)
      end

      def pop
        @redis.spop(@redis_session_key)
      end

      def log_failure(spec_file)
        @redis.sadd(@redis_session_failure_key, [spec_file])
      end

      def log_result(spec_file, result, props = {})
        logged_payload = props.merge({
          test: spec_file,
          passed: result
        })
        @redis.sadd(@redis_session_result_key, JSON.dump(logged_payload))
      end

      def fpop
        @redis.spop(@redis_session_retry_key)
      end
    end
  end
end