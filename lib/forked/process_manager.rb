require 'logger'
require 'timeout'

module Forked
  class ProcessManager
    def initialize(process_timeout: 5, logger: Logger.new(STDOUT))
      @process_timeout = process_timeout
      @workers = {}
      @logger = logger
    end

    def fork(name = nil, retry_strategy: ::Forked::RetryStrategies::ExponentialBackoff, on_error: -> (e) {}, &block)
      worker = Worker.new(name, retry_strategy, on_error, block)
      fork_worker(worker)
    end

    def wait_for_shutdown
      trap_shutdown_signals
      handle_child_processes
      shutdown
    end

    def shutdown
      @logger.info "Master shutting down"
      send_signal_to_workers(:TERM)
      wait_for_workers_until_timeout
      send_signal_to_workers(:KILL)
      @logger.info "Master shutdown complete"
    end

    def worker_pids
      @workers.keys
    end

    private

    def fork_worker(worker)
      retry_strategy = worker.retry_strategy.new(logger: @logger, on_error: worker.on_error)
      pid = Kernel.fork do
        WithGracefulShutdown.run(logger: @logger) do |ready_to_stop|
          retry_strategy.run(ready_to_stop) do
            if worker.block.arity > 0
              worker.block.call(ready_to_stop)
            else
              worker.block.call
            end
          end
        end
      end
      @workers[pid] = worker
    end

    def handle_child_processes
      until @shutdown_requested
        # Returns nil immediately if no child process exists
        pid, status = Process.wait2(-1, Process::WNOHANG)
        if pid
          handle_child_exit(pid, status)
        end
        sleep(0.5)
      end
    end

    def handle_child_exit(pid, status)
      worker = @workers.delete(pid)
      if status.exited?
        @logger.info "#{worker.name || pid} exited with status #{status.exitstatus.inspect}"
      else
        @logger.info "#{worker.name || pid} terminated"
      end
      if status.exitstatus.nil? || status.exitstatus.nonzero?
        @logger.error "Restarting #{worker.name || pid}"
        fork_worker(worker)
      end
    end

    def trap_shutdown_signals
      %i(TERM INT).each do |signal|
        Signal.trap(signal) do
          start_shutdown
        end
      end
    end

    def start_shutdown
      @shutdown_requested = true
    end

    def wait_for_workers_until_timeout
      @waiting_since = Time.now
      until @workers.empty? || timed_out?(@waiting_since)
        # Returns nil immediately if no child process exists
        pid, status = Process.wait2(-1, Process::WNOHANG)
        @workers.delete(pid) if pid
      end
    end

    def send_signal_to_workers(signal)
      if !@workers.empty?
        @logger.info "Sending #{signal} to #{@workers.keys}"
        @workers.each_key do |pid|
          begin
            Process.kill(signal, pid)
          rescue Errno::ESRCH => e
            # Errno::ESRCH: No such process
            # Move along if the process is already dead
            @workers.delete(pid)
          end
        end
      end
    end

    def timed_out?(waiting_since)
      Time.now > (waiting_since + @process_timeout)
    end
  end
end
