class Analytics::API
  # Stores meta data on the experiment.
  #
  # The uncontrolled_vars array tells what vars will be used to the analysis.
  # You can store uncontrolled vars in the observations but pass [] here and
  # they won't be used in the analysis.
  # /!\ You cannot use a subset of the uncontrolled_vars yet, it's all or [].
  def self.register_experiment(expt_id, profile_ids, input_ids, uncontrolled_vars, profiles_percent_with_inputs)
    raise "wrong arguments in Analytics::API.register_experiment" unless (
      expt_id.kind_of?(String) && profile_ids.kind_of?(Array) && input_ids.kind_of?(Array) &&
      uncontrolled_vars.kind_of?(Array)
    )
    Analytics::ExperimentMeta.register(expt_id, profile_ids, input_ids, uncontrolled_vars, profiles_percent_with_inputs)
  end

  # Updates observations and mappings counters with the data
  #
  # context_ids cannot be [] or it won't store anything.
  #
  # output_ids can be []. E.g., if you go on a page but don't see any ad,
  # still make a call to update the mappings.
  #
  # If you want diffenrent granularities (e.g. sites, pages, trackers),
  # call if multiple times with the right contexts.
  # In this case, don't forget to change the expt_id (e.g. name_sites,
  # same_trackes) or you will just overwrite the rows and lose the data.
  def self.add_observation(expt_id, profile_id, context_ids, uncontrolled_vars,
                           output_ids, options={})
    raise "wrong arguments in Analytics::Observation.add" unless (
      expt_id.kind_of?(String) && profile_id.kind_of?(String) && context_ids.kind_of?(Array) &&
      uncontrolled_vars.kind_of?(Hash) && output_ids.kind_of?(Array)
    )
    default_options = {
      :count          => 1,
      :update_mapping => true,
    }
    options.reverse_merge!(default_options)

    context_ids.each do |context_id|
      # we add the mapping only if there is a meaningful context and we should
      # update the mappings
      if profile_id != context_id && options[:update_mapping]
        Analytics::Mapping.add(expt_id, profile_id, context_id, uncontrolled_vars,
                               options[:count])
      end
      output_ids.each do |output_id|
        Analytics::Observation.add(expt_id, profile_id, context_id, uncontrolled_vars,
                                   output_id, options[:count])
      end
    end
  end

  # chose algorithms between:
  # * logit_simple
  # * lm_simple
  # * logit_full
  # * lm_full
  # * naive_bayes
  # * set_intersection
  # This will always compute pvalues
  def self.analyse(expt_id, output_id, options={})
    default_options = {
      :async                => false,
      :bulk                 => false,
      :queue_name           => 'algorithm',  # queue name if async
      :algorithms           => [],           # see function comment
      :only_expt_inputs     => false,        # only add inputs declared in the experiment
                                             # as analysis variables
      :store_results        => false,
      :max_combination_size => 5,            # max combination size
      :training_percent     => 0.7,          # if you compute pvalues, you use training_percent
                                             # of the profiles as training, the rest as
                                             # testing
      :remove_observations  => [],           # an array of input_ids to remove observations from
      # :parameters           => {},         # fromat :algo => {params}, params will be passed
                                             # as parameter field when calling the algo
    }
    options.reverse_merge!(default_options)

    if options[:async]
      if options[:bulk]
        return [expt_id, output_id, options]
      else
        AlgorithmWorker.perform_in_queue(options[:queue_name], expt_id, output_id, options)
      end
    else
      Analytics::Pipeline::Analysis.run_analysis(expt_id, output_id, options)
    end
  end

  def self.get_hypothesis(expt_id, output_id, algorithms)
    s_algorithms = algorithms.map(&:to_s)
    hypothesis = Analytics::Hypothesis.get_output(expt_id, output_id).to_a
    hypothesis = hypothesis.select { |h| s_algorithms.include?(h['algorithm_type']) }
              .map do |h|
                [h['algorithm_type'].to_sym,
                { :guesses     => JSON.parse(h['input_ids']),
                  :pvalue      => h['pvalue'],
                  :pvalue_by   => h['corr_by_pvalue'],
                  :pvalue_holm => h['corr_holm_pvalue'],
                }]
              end
   Hash[hypothesis]
  end

  def self.correct_pvalues(expt_id, algorithms)
    algorithms.each do |algorithm|
      hypothesis = Analytics::Hypothesis.get_algorithm(expt_id, algorithm)
      data = hypothesis.map do |h|
        [[expt_id, h['output_id'], algorithm], h['pvalue']]
      end.select { |d| !!d[-1] }
      pvalues = data.map(&:last)
      corr_by_pvalues   = Analytics::Evaluation.correct_pvalues(pvalues, :correction_method => :BY)
      corr_holm_pvalues = Analytics::Evaluation.correct_pvalues(pvalues, :correction_method => :holm)
      data.each_with_index do |d, i|
        Analytics::Hypothesis.set_corrected_pvalues(d[0], corr_by_pvalues[i], corr_holm_pvalues[i])
      end.each(&:join)
    end
  end

  #########
  # Utils #
  #########

  # just a convenience function, see analyse
  def self.analyse_all(expt_id, options)
    output_ids = Analytics::Observation.get_all_expt_outputs(expt_id)
    if options[:async]
      options[:bulk] = true
      args = output_ids.map do |output_id|
        self.analyse(expt_id, output_id, options)
      end
      args.each_slice(1000) do |args_slice|
        AlgorithmWorker.perform_bulk_in_queue(options[:queue_name], args_slice)
      end
    else
      output_ids.each do |output_id|
        self.analyse(expt_id, output_id, options)
      end
    end
  end

  # Used to retrieve the data for the analysis. #
  def self.expt_data(expt_id)
    expt_meta    = Analytics::ExperimentMeta.get(expt_id).first
    expt_meta    = Hash[expt_meta.map do |k, v|
      if k.to_s == 'expt_id'
        [k, v]
      elsif k.to_s == 'profiles_percent_with_inputs'
        [k, (v || 0.5).to_f]
      else
        [k, JSON.parse(v)]
      end
    end]
    mappings     = Analytics::Mapping.get_expt(expt_id).to_a
    { :expt_meta    => expt_meta,
      :mappings     => mappings, }
  end

  def self.ouput_data(expt_id, output_id, options={})
    default_options = { :also_fetch_expt_data => true, }
    options.reverse_merge!(default_options)

    result = {}
    if options[:also_fetch_expt_data]
      expt_meta    = Analytics::ExperimentMeta.get(expt_id).first
      expt_meta    = Hash[expt_meta.map do |k, v|
        if k.to_s == 'expt_id'
          [k, v]
        elsif k.to_s == 'profiles_percent_with_inputs'
          [k, (v || 0.5).to_f]
        else
          [k, JSON.parse(v)]
        end
      end]
      result[:expt_meta] = expt_meta
      result[:mappings]  = Analytics::Mapping.get_expt(expt_id).to_a
    end
    result[:observations] = Analytics::Observation.get_expt_output(expt_id, output_id).to_a
    result
  end

  def self.synchronize_schemas
    Analytics::ExperimentMeta.synchronize_schema
    Analytics::Hypothesis.synchronize_schema
    Analytics::Mapping.synchronize_schema
    Analytics::Observation.synchronize_schema
  end
end
