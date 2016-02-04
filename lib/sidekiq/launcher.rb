require 'sidekiq/actor'
require 'sidekiq/manager'
require 'sidekiq/fetch'
require 'sidekiq/scheduled'

module Sidekiq
  # The Launcher is a very simple Actor whose job is to
  # start, monitor and stop the core Actors in Sidekiq.
  # If any of these actors die, the Sidekiq process exits
  # immediately.
  class Launcher
    include Actor
    include Util

    trap_exit :actor_died

    attr_reader :manager, :poller, :fetcher

    def initialize(options)
      @condvar = Celluloid::Condition.new
      @manager = Sidekiq::Manager.new_link(@condvar, options)
      @poller = Sidekiq::Scheduled::Poller.new_link
      @fetcher = Sidekiq::Fetcher.new_link(@manager, options)
      @manager.fetcher = @fetcher
      @done = false
      @options = options
    end

    def actor_died(actor, reason)
      # https://github.com/mperham/sidekiq/issues/2057#issuecomment-66485477
      return if @done || !reason

      Sidekiq.logger.warn("Sidekiq died due to the following error, cannot recover, process exiting")
      handle_exception(reason)
      exit(1)
    end

    def run
      watchdog('Launcher#run') do
        manager.async.start
        poller.async.poll(true)

        start_heartbeat
      end
    end

    def stop
      watchdog('Launcher#stop') do
        @done = true
        Sidekiq.logger.info "#stop Sidekiq::Fetcher.done!"
        Sidekiq::Fetcher.done!
        Sidekiq.logger.info "#stop fetcher.terminate"
        fetcher.terminate if fetcher.alive?
        Sidekiq.logger.info "#stop poller.terminate"
        poller.terminate if poller.alive?

        Sidekiq.logger.info "#stop manager.async.stop"
        manager.async.stop(:shutdown => true, :timeout => @options[:timeout])
        Sidekiq.logger.info "#stop fire_event(:shutdown, true)"
        fire_event(:shutdown, true)
        wait_timeout = @options[:timeout] ? @options[:timeout] + 1 : nil
        Sidekiq.logger.info "#stop condvar.wait(#{wait_timeout}) object_id:#{@condvar.object_id}"
        begin
          @condvar.wait(wait_timeout)
        rescue Celluloid::ConditionError => e
          if e.message.start_with?('timeout')
            Sidekiq.logger.info "#{e.class} #{e.message}"
          else
            raise e
          end
        end
        Sidekiq.logger.info "#stop manager.terminate"
        manager.terminate

        # Requeue everything in case there was a worker who grabbed work while stopped
        # This call is a no-op in Sidekiq but necessary for Sidekiq Pro.
        Sidekiq.logger.info "#stop Sidekiq::Fetcher.strategy.bulk_requeue"
        Sidekiq::Fetcher.strategy.bulk_requeue([], @options)

        Sidekiq.logger.info "#stop stop_heartbeat"
        stop_heartbeat
      end
    end

    private

    def start_heartbeat
      key = identity
      data = {
        'hostname' => hostname,
        'started_at' => Time.now.to_f,
        'pid' => $$,
        'tag' => @options[:tag] || '',
        'concurrency' => @options[:concurrency],
        'queues' => @options[:queues].uniq,
        'labels' => Sidekiq.options[:labels],
        'identity' => identity,
      }
      # this data doesn't change so dump it to a string
      # now so we don't need to dump it every heartbeat.
      json = Sidekiq.dump_json(data)
      manager.heartbeat(key, data, json)
    end

    def stop_heartbeat
      Sidekiq.redis do |conn|
        conn.pipelined do
          conn.srem('processes', identity)
          conn.del("#{identity}:workers")
        end
      end
    rescue
      # best effort, ignore network errors
    end

  end
end
