class AlgorithmWorker
  include Sidekiq::Worker
  sidekiq_options :retry => 3
  sidekiq_options :queue => :algorithm

  def perform(expt_id, output_id, options)
    options = options.symbolize_keys
    options[:algorithms].map(&:to_sym)
    options[:store_results] = true  # or it's useless
    options[:async] = false
    Analytics::API.analyse(expt_id, output_id, options)
  end

  # args are the same as for perform
  def self.perform_in_queue(queue_name, expt_id, output_id, options)
    options = options.symbolize_keys
    options[:algorithms].map(&:to_sym)
    options[:store_results] = true  # or it's useless
    options[:async] = false
    Sidekiq::Client.push(
      'class' => AlgorithmWorker,
      'args' => [expt_id, output_id, options],
      'queue' => queue_name
    )
  end

  # args are the same as for perform
  def self.perform_bulk_in_queue(queue_name, args)
    args.map! do |arg|
      options = arg.last.symbolize_keys
      options[:algorithms].map(&:to_sym)
      options[:store_results] = true  # or it's useless
      options[:async] = false
      arg[-1] = options
      arg
    end
    Sidekiq::Client.push_bulk('queue' => queue_name,
                              'class' => AlgorithmWorker,
                              'args'  => args)
  end
end
