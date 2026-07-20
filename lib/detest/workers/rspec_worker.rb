require 'rspec/core'

module Detest
  module Workers
    class RspecWorker
      def initialize(args)
        @options = RSpec::Core::ConfigurationOptions.new(args)
        @runner = RSpec::Core::Runner.new(@options)
        @runner.configure($stderr, $stdout)
        @configuration = @runner.configuration
        @our_cwd = Dir.pwd
        setup
        @reporter = @runner.configuration.reporter
        @reporter.start(0)
        @passed = true
      end

      def setup
        @configuration.load_spec_files
      ensure
        @runner.world.announce_filters
      end

      def run(adapter)
        adapter.record_worker
        @configuration.with_suite_hooks do
          run_until_empty(adapter)
        end
      ensure
        adapter.close
      end

      # The adapter already chose the set to drain (published specs on attempt
      # 1, the prior attempt's failures on a rerun). Failures are logged to a
      # separate per-attempt set, so nothing recorded here can re-enter this
      # loop.
      def run_until_empty(adapter)
        while spec = adapter.pop
          run_spec(adapter, spec)
          bail?(adapter, spec)
        end
        finish(adapter)
      end

      def bail?(adapter, spec)
        if RSpec.world.wants_to_quit
          adapter.log_failure(spec)
          @reporter.finish
          adapter.end_worker
          exit(1)
        end
      end

      def finish(adapter)
        @reporter.finish
        adapter.end_worker
        exit(exit_code(@passed))
      end

      def exit_code(passed)
        return 1 unless passed
        0
      end

      def run_spec(adapter, spec_path)
        start_time = Time.now
        example_groups = @runner.world.example_groups.select do |eg|
          Pathname(File.expand_path(eg.file_path)).relative_path_from(@our_cwd).to_s == spec_path
        end

        examples_count = @runner.world.example_count(example_groups)

        egs_passed = example_groups.map { |g| g.run(@reporter) }.all?
        end_time = Time.now
        time_elapsed = end_time - start_time
        adapter.log_result(
          spec_path,
          egs_passed,
          {
            duration: time_elapsed
          }
        )
        adapter.log_failure(spec_path) unless egs_passed

        @passed = @passed && egs_passed
      end

      def self.boot(args)
        RSpec::Core::Runner.disable_autorun!
        RSpec::Core::Runner.trap_interrupt
        new(args)
      end
    end
  end
end
