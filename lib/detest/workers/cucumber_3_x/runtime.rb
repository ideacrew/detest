require "cucumber/runtime"

module Detest
  module Workers
    module Cucumber
      class Runtime < ::Cucumber::Runtime
        def test_file_started(event)
          @test_start_time = Time.now
          @current_test_file = event.path
          @passing = true
        end

        def test_case_finished(event)
          @passing = false if event.result.failed?
        end

        def test_file_finished(event)
          test_end_time = Time.now
          unless @passing
            @adapter.log_failure(@current_test_file)
          end
          time_elapsed = test_end_time - @test_start_time
          @adapter.log_result(
            @current_test_file,
            @passing,
            {
              duration: time_elapsed
            }
          )
          @test_start_time = nil
          @current_test_file = nil
        end

        def run!(adapter)
          @adapter = adapter
          load_step_definitions
          install_wire_plugin
          fire_after_configuration_hook
          # TODO: can we remove this state?
          self.visitor = report
    
          receiver = ::Cucumber::Core::Test::Runner.new(@configuration.event_bus)

          @configuration.event_bus.on(:test_file_started) do |event|
            self.test_file_started(event)
          end

          @configuration.event_bus.on(:test_file_finished) do |event|
            self.test_file_finished(event)
          end

          @configuration.event_bus.on(:test_case_finished) do |event|
            self.test_case_finished(event)
          end

          adapter.record_worker
          while f_file = adapter.pop
            @configuration.notify :test_file_started, f_file
            fs = process_feature_file(f_file)
            compile fs, receiver, filters
            @configuration.notify :test_file_finished, f_file
          end
          @configuration.notify :test_run_finished
          adapter.end_worker
        end

        def process_feature_file(file)
          f_filespecs = ::Cucumber::FileSpecs.new([file])
          f_files = f_filespecs.files
          f_files.map do |path|
            source = NormalisedEncodingFile.read(path)
            @configuration.notify :gherkin_source_read, path, source
            ::Cucumber::Core::Gherkin::Document.new(path, source)
          end
        end
      end
    end
  end
end