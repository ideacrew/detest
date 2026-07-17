namespace :self_test do
  desc "Run rspec tests using myself"
  task :rspec do
    require 'open3'
    require 'pty'
    cmd = "bundle exec ruby rspec_publisher_example.rb --require spec_helper.rb examples"
    PTY.spawn(cmd) do |stdout, stdin, pid|
      while (data = stdout.read(1))
        print data
      end
    end

    cmd = "bundle exec ruby rspec_worker_example.rb --require spec_helper.rb --format progress --force-color examples"
    PTY.spawn(cmd) do |stdout, stdin, pid|
      while (data = stdout.read(1))
        print data
      end
    end

    cmd = "DETEST_RUN_ATTEMPT=2 bundle exec ruby rspec_worker_example.rb --require spec_helper.rb --format progress --force-color examples"
    PTY.spawn(cmd) do |stdout, stdin, pid|
      while (data = stdout.read(1))
        print data
      end
    end
  end
end