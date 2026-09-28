require "redis"
require "json"

module Detest
  module Adapters
    class RedisAdapter
      # Raised by `fpop` when a rerun's retry queue can't be found. This means
      # either the session's keys expired (see DEFAULT_KEY_TTL_SECONDS) or the
      # original attempt never got as far as finalizing one, in which case
      # treating an empty result as "nothing to rerun" would be a false pass.
      class MissingRetryQueueError < StandardError; end

      # ideacrew/enroll's full-suite.yml sets DETEST_SESSION_ID to the GitHub
      # Actions run ID, which stays constant across "re-run failed jobs"
      # attempts (github.run_attempt just increments) for as long as GitHub
      # allows reruns at all. That's the clock that matters here, not job
      # duration: a rerun that lands after these keys expire must not be
      # mistaken for "no failures" (see MissingRetryQueueError / `fpop`).
      #
      # Pinned to ideacrew/enroll's own .github/workflows/stale.yml, which
      # auto-closes an inactive PR 30 days (days-before-stale) + 7 days
      # (actions/stale's default days-before-close, not overridden there)
      # after its last activity — 37 days. That's also comfortably past
      # GitHub's own 30-day rerun limit, so it bounds key growth while
      # outlasting every rerun window a still-open PR could hit.
      ENROLL_STALE_PR_DAYS = 30
      ENROLL_STALE_PR_CLOSE_GRACE_DAYS = 7
      DEFAULT_KEY_TTL_SECONDS = (ENROLL_STALE_PR_DAYS + ENROLL_STALE_PR_CLOSE_GRACE_DAYS) * 24 * 60 * 60

      attr_reader :redis, :redis_session_key, :redis_session_failure_key,
                  :redis_session_retry_key, :redis_session_runner_key,
                  :redis_session_result_key, :redis_session_finalized_key

      def initialize(session_key, *args, ttl: DEFAULT_KEY_TTL_SECONDS, **kwargs)
        @redis = Redis.new(*args, **kwargs)
        @ttl = Integer(ttl)
        @redis_session_key = "__#{session_key}_tp_adapter_test_storage"
        @redis_session_failure_key = "__#{session_key}_tp_adapter_test_failure_storage"
        @redis_session_result_key = "__#{session_key}_tp_adapter_test_results_storage"
        @redis_session_runner_key = "__#{session_key}_tp_adapter_test_runner_count_storage"
        @redis_session_retry_key = "__#{session_key}_tp_adapter_test_retry_error_storage"
        @redis_session_finalized_key = "__#{session_key}_tp_adapter_test_finalized_storage"
      end

      def close
        @redis.disconnect!
      end

      def record_worker(pipeline = nil)
        if pipeline
          pipeline.incr(@redis_session_runner_key)
          pipeline.expire(@redis_session_runner_key, @ttl)
        else
          @redis.pipelined do |p|
            p.incr(@redis_session_runner_key)
            p.expire(@redis_session_runner_key, @ttl)
          end
        end
      end

      def end_worker(pipeline = nil)
        if pipeline
          decr = pipeline.decr(@redis_session_runner_key)
          pipeline.expire(@redis_session_runner_key, @ttl)
        else
          decr, = @redis.pipelined do |p|
            p.decr(@redis_session_runner_key)
            p.expire(@redis_session_runner_key, @ttl)
          end
        end

        finalize(pipeline || @redis) if decr < 1
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

      # Rerun-only. Distinguishes a genuinely-empty retry queue (nothing left
      # to rerun) from a missing/expired one (can't tell whether there was
      # anything to rerun) by checking the finalized marker `end_worker`
      # always writes, even when there were zero failures to carry over.
      # Without this, an expired retry key reads identically to "no
      # failures" and a rerun exits 0 without having run anything.
      def fpop
        unless @redis.exists?(@redis_session_finalized_key)
          raise MissingRetryQueueError,
                "retry queue for #{@redis_session_retry_key} is missing or expired; " \
                "cannot tell whether there were failures to rerun"
        end

        @redis.spop(@redis_session_retry_key)
      end

      private

      # Called once, by whichever worker is the last to finish (decr < 1).
      # Always writes the finalized marker, even when there's nothing to
      # move, so `fpop` can tell "finalized with zero failures" apart from
      # "never finalized" (expired or the run never got this far).
      def finalize(conn)
        smem = conn.smembers(@redis_session_failure_key)
        smem.each do |smember|
          conn.smove(@redis_session_failure_key, @redis_session_retry_key, smember)
        end
        conn.expire(@redis_session_retry_key, @ttl) if smem.any?
        conn.set(@redis_session_finalized_key, "1", ex: @ttl)
      end
    end
  end
end