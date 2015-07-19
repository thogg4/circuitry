require 'timeout'
require 'circuitry/concerns/async'
require 'circuitry/services/sqs'
require 'circuitry/message'

module Circuitry
  class SubscribeError < StandardError; end

  class Subscriber
    include Concerns::Async
    include Services::SQS

    attr_reader :queue, :timeout, :wait_time, :batch_size, :lock_strategy

    DEFAULT_OPTIONS = {
        async: false,
        timeout: 15,
        wait_time: 10,
        batch_size: 10,
        lock_strategy: Circuitry::Locks::Memory.new,
    }.freeze

    CONNECTION_ERRORS = [
        Excon::Errors::Forbidden,
    ].freeze

    def initialize(queue, options = {})
      raise ArgumentError.new('queue cannot be nil') if queue.nil?

      options = DEFAULT_OPTIONS.merge(options)

      self.queue = queue
      self.async = options[:async]
      self.timeout = options[:timeout]
      self.wait_time = options[:wait_time]
      self.batch_size = options[:batch_size]
      self.lock_strategy = options[:lock_strategy]
    end

    def subscribe(&block)
      raise ArgumentError.new('block required') if block.nil?

      unless can_subscribe?
        logger.warn('Circuitry unable to subscribe: AWS configuration is not set.')
        return
      end

      loop do
        begin
          receive_messages(&block)
        rescue *CONNECTION_ERRORS => e
          logger.error("Connection error to #{queue}: #{e}")
          raise SubscribeError.new(e)
        end
      end
    end

    def self.async_strategies
      super - [:batch]
    end

    def self.default_async_strategy
      Circuitry.config.subscribe_async_strategy
    end

    protected

    attr_writer :queue, :timeout, :wait_time, :batch_size

    def lock_strategy=(value)
      unless value.is_a?(Circuitry::Locks::Base)
        raise ArgumentErrot, "invalid value `#{value}`, must be instance of `#{Circuitry::Locks::Base}`"
      end

      @lock_strategy = value
    end

    private

    def receive_messages(&block)
      response = sqs.receive_message(queue, 'MaxNumberOfMessages' => batch_size, 'WaitTimeSeconds' => wait_time)
      messages = response.body['Message']
      return if messages.empty?

      messages.each do |message|
        process = -> do
          process_message(message, &block)
        end

        if async?
          process_asynchronously(&process)
        else
          process.call
        end
      end
    end

    def process_message(message, &block)
      message = Message.new(message)

      Timeout.timeout(timeout) do
        logger.info("Processing message #{message.id}")
        handle_message(message, &block)
        delete_message(message)
      end
    rescue => e
      logger.error("Error processing message #{message.id}: #{e}")
      error_handler.call(e) if error_handler
    end

    def handle_message(message, &block)
      if lock_strategy.soft_lock(message.id)
        begin
          block.call(message.body, message.topic.name)
        rescue => e
          logger.error("Error handling message #{message.id}: #{e}")
          raise e
        end

        lock_strategy.hard_lock(message.id)
      else
        logger.info("Ignoring duplicate message #{message.id}")
      end
    end

    def delete_message(message)
      logger.info("Removing message #{message.id} from queue")
      sqs.delete_message(queue, message.receipt_handle)
    end

    def logger
      Circuitry.config.logger
    end

    def error_handler
      Circuitry.config.error_handler
    end

    def can_subscribe?
      Circuitry.config.aws_options.values.all? do |value|
        !value.nil? && !value.empty?
      end
    end
  end
end
