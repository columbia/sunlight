class Analytics::Pipeline::Analysis
  def self.run_analysis(expt_id, output_id, options={})
    default_options = {
      :algorithms           => [],
      :only_expt_inputs     => false,
      :store_results        => false,
      :profile_ids          => :all,  # :all or an array of profile_ids
      :training_percent     => 0.7,
      :max_combination_size => 5,     # max combination size
      :remove_observations  => [],
    }
    options.reverse_merge!(default_options)
    options[:algorithms].map!(&:to_sym)

    data           = Analytics::API.ouput_data(expt_id, output_id)
    if options[:remove_observations].count > 0
      data[:observations].select! { |obs| !options[:remove_observations].include?(obs["output_id"]) }
    end
    options[:data] = data

    profile_ids   = data[:mappings].map { |m| m['profile_id'] }.uniq
    training_size = (profile_ids.count.to_f * options[:training_percent]).ceil
    training_set, testing_set = profile_ids.shuffle.each_slice(training_size).to_a

    results = options[:algorithms].map do |algorithm|
      pipeline =
        case algorithm
        when :logit_simple
          { :sparse     => Analytics::Sparse::LogitSimple,
            :filters    => [Analytics::Filter::Accuracy, Analytics::Filter::Pvalue],
            :confidence => Analytics::Confidence::Pvalue, }
        when :lm_full
          { :sparse     => Analytics::Sparse::LmFull,
            :filters    => [Analytics::Filter::Accuracy, Analytics::Filter::Pvalue],
            :confidence => Analytics::Confidence::Pvalue, }
        when :set_intersection
          { :sparse     => Analytics::Sparse::SetIntersection,
            :filters    => [Analytics::Filter::Accuracy, Analytics::Filter::Pvalue],
            :confidence => Analytics::Confidence::Pvalue, }
        when :naive_bayes
          { :sparse     => Analytics::Sparse::NaiveBayes,
            :filters    => [Analytics::Filter::Accuracy, Analytics::Filter::Pvalue],
            :confidence => Analytics::Confidence::Pvalue, }
        end
      result = self.pipeline(expt_id, output_id, pipeline, training_set, testing_set, options.clone)
      result[:training_set] = training_set
      result[:testing_set]  = testing_set
      if options[:store_results]
        # we also store the pipeline and the options to be able to reference it
        # later on
        result[:pipeline] = {
          :sparse     => pipeline[:sparse].to_s,
          :filters    => pipeline[:filters].map(&:to_s),
          :confidence => pipeline[:confidence].to_s,
        }
        result[:options] = options.merge({ :data => nil })
        Analytics::Hypothesis.add(expt_id, output_id, algorithm,
                                  result[:guess],
                                  result[:results][:filters].map { |x| x[:pvalue] },
                                  result[:pvalue],
                                  result)
      end
      [algorithm, result]
    end
    return Hash[results]
  end

  def self.pipeline(expt_id, output_id, pipeline, training_set, testing_set, options={})
    default_options = {
      :only_expt_inputs     => false,
      :max_combination_size => 5,     # max combination size
    }
    options.reverse_merge!(default_options)

    trace = { :results => { :sparse  => nil, :filters => [] },
              :guess   => nil,
              :pvalue  => nil }

    results  = pipeline[:sparse].analyse(expt_id, output_id, options)
    accuracy = self.evaluate_predictions(expt_id, output_id, testing_set,
                                         pipeline[:sparse], results, options)
    trace[:results][:sparse] = { :results => results, :accuracy => accuracy }
    ordered_inputs           = pipeline[:sparse].ordered_inputs(results)

    pvalue = nil
    pipeline[:filters].each do |filter|
      ordered_inputs = filter.filter(expt_id, output_id, training_set, ordered_inputs, options)
      accuracy = self.evaluate_predictions(expt_id, output_id, testing_set, filter,
                                           ordered_inputs, options)
      pvalue = nil
      if ordered_inputs.count > 0
        pvalue = pipeline[:confidence].pvalue(expt_id, output_id, ordered_inputs,
                                              testing_set, options)
      end
      trace[:results][:filters].push({ :results  => ordered_inputs,
                                       :accuracy => accuracy,
                                       :pvalue   => pvalue })
    end

    trace[:guess] = ordered_inputs
    trace[:pvalue] = pvalue

    return trace
  end

  def self.evaluate_predictions(expt_id,
                                output_id,
                                testing_set,
                                pipeline_class,
                                pipeline_data,
                                options={})
    default_options = {
      :data             => nil,      # potential precomputed data matrix
      :algorithms       => [],
      :only_expt_inputs => false,
      :store_results    => false,
      :profile_ids      => :all,  # :all or an array of profile_ids
    }
    options.reverse_merge!(default_options)

    data = options[:data] || Analytics::API.ouput_data(expt_id, output_id)
    mappings     = data[:mappings]
    observations = data[:observations]
    expt_meta    = data[:expt_meta]
    # mappings_hash full and no uncontroller_vars
    # is a hash of { profile_id => input_id => #displays }
    mappings_full_hash = Analytics::FormatData.hash_from_cassandra_rows(
      mappings,
      [],
      :model => :full,
      :profile_ids => testing_set,
      :hash_inputs => false
    )
    # observations_hash simple and no uncontroller_vars
    # is a hash of { profile_id => #displays }
    observations_hash = Analytics::FormatData.hash_from_cassandra_rows(
      observations,
      [],
      :model => :simple,
      :profile_ids => testing_set,
      :hash_inputs => false
    )

    input_ids = mappings_full_hash.map { |_, v| v.keys }.flatten.uniq.sort
    # remove non expt_inputs if necessary
    if options[:only_expt_inputs]
      input_ids = input_ids & expt_meta['input_ids']
    end

    predictions_stats = {
      :total => 0,
      :tp    => 0,
      :fp    => 0,
      :tn    => 0,
      :fn    => 0,
    }
    testing_set.each do |profile_id|
      predictions_stats[:total] += 1
      inputs_in_profile = mappings_full_hash[profile_id].keys
      prediction = pipeline_class.predict_output_presence(pipeline_data, inputs_in_profile)
      if prediction
        # there is at least one input guessed, we predict we should see the ad
        if observations_hash[profile_id] && observations_hash[profile_id] > 0
          # we do see the ad
          predictions_stats[:tp] += 1
        else
          predictions_stats[:fp] += 1
        end
      else
        if observations_hash[profile_id] && observations_hash[profile_id] > 0
          # we do see the ad
          predictions_stats[:fn] += 1
        else
          predictions_stats[:tn] += 1
        end
      end
    end

    return predictions_stats
  end
end
