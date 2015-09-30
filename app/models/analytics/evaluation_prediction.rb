class Analytics::EvaluationPrediction
  def self.evaluate_predictions(expt_id,
                                algorithm,
                                output_id,
                                training_set,
                                testing_set,
                                guesses,
                                params,  # must be a hash of { input_id => float param }
                                options={})
    default_options = {
      :only_expt_inputs => false,
    }
    options.reverse_merge!(default_options)

    return nil if guesses.count == 0

    data         = Analytics::API.ouput_data(expt_id, output_id)
    mappings     = data[:mappings]
    observations = data[:observations]
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

    profiles_count = testing_set.count
    profiles_w_ad = observations_hash.select { |profile_id, displays| displays > 0 }.count
    profiles_wo_ad = profiles_count - profiles_w_ad

    params_predictions_stats = {
      :total => 0,
      :tp    => 0,
      :fp    => 0,
      :tn    => 0,
      :fn    => 0,
    }
    or_predictions_stats = {
      :total => 0,
      :tp    => 0,
      :fp    => 0,
      :tn    => 0,
      :fn    => 0,
    }
    if algorithm.to_s.include?('logit')    ||
       algorithm.to_s.include?('logistic') ||
       algorithm.to_s.include?('binomial')
      threshold = params["(Intercept)"] || 0
    else
      threshold = self.compute_best_param_prediction_threshold(expt_id,
                                                               output_id,
                                                               data,
                                                               training_set,
                                                               params)
    end
    testing_set.each do |profile_id|
      params_predictions_stats[:total] += 1
      account_input_ids = mappings_full_hash[profile_id].keys & input_ids
      if (self.compute_param_prediction_score(account_input_ids, params) || 0) >= threshold
        # we predict we should see the ad
        if observations_hash[profile_id] && observations_hash[profile_id] > 0
          # we do see the ad
          params_predictions_stats[:tp] += 1
        else
          params_predictions_stats[:fp] += 1
        end
      else
        if observations_hash[profile_id] && observations_hash[profile_id] > 0
          # we do see the ad
          params_predictions_stats[:fn] += 1
        else
          params_predictions_stats[:tn] += 1
        end
      end

      or_predictions_stats[:total] += 1
      if (mappings_full_hash[profile_id].keys & guesses).count > 0
        # there is at least one input guessed, we predict we should see the ad
        if observations_hash[profile_id] && observations_hash[profile_id] > 0
          # we do see the ad
          or_predictions_stats[:tp] += 1
        else
          or_predictions_stats[:fp] += 1
        end
      else
        if observations_hash[profile_id] && observations_hash[profile_id] > 0
          # we do see the ad
          or_predictions_stats[:fn] += 1
        else
          or_predictions_stats[:tn] += 1
        end
      end
    end

    params_predictions_stats[:precision] = params_predictions_stats[:tp] /
      (params_predictions_stats[:tp] + params_predictions_stats[:fp]).to_f rescue 0
    params_predictions_stats[:recall] = params_predictions_stats[:tp] /
      (params_predictions_stats[:tp] + params_predictions_stats[:fn]).to_f rescue 0
    params_predictions_stats[:accuracy] =
      (params_predictions_stats[:tp] + params_predictions_stats[:tn]) /
      params_predictions_stats[:total].to_f rescue 0
    or_predictions_stats[:precision] = or_predictions_stats[:tp] /
      (or_predictions_stats[:tp] + or_predictions_stats[:fp]).to_f rescue 0
    or_predictions_stats[:recall] = or_predictions_stats[:tp] /
      (or_predictions_stats[:tp] + or_predictions_stats[:fn]).to_f rescue 0
    or_predictions_stats[:accuracy] = (or_predictions_stats[:tp] + or_predictions_stats[:tn]) /
      or_predictions_stats[:total].to_f rescue 0

    return {
      :profiles_n => profiles_count,
      :profiles_w_ad_n => profiles_w_ad,
      :profiles_wo_ad_n => profiles_wo_ad,
      :or_predictions => or_predictions_stats,
      :params_predictions => params_predictions_stats,
    }
  end

  # params must be a hash of { input_id => float param }
  def self.compute_best_param_prediction_threshold(expt_id,
                                                   output_id,
                                                   data,
                                                   training_set,
                                                   params,
                                                   options={})
    # compute scores for each account, and cross-validate to
    # pick threshold with best accuracy(? or ROC/AUC)
    default_options = {
      :only_expt_inputs => false,
    }
    options.reverse_merge!(default_options)

    mappings     = data[:mappings]
    observations = data[:observations]
    # mappings_hash full and no uncontroller_vars
    # is a hash of { profile_id => input_id => #displays }
    mappings_full_hash = Analytics::FormatData.hash_from_cassandra_rows(
      mappings,
      [],
      :model => :full,
      :profile_ids => training_set,
      :hash_inputs => false
    )
    # observations_hash simple and no uncontroller_vars
    # is a hash of { profile_id => #displays }
    observations_hash = Analytics::FormatData.hash_from_cassandra_rows(
      observations,
      [],
      :model => :simple,
      :profile_ids => training_set,
      :hash_inputs => false
    )

    input_ids = mappings_full_hash.map { |_, v| v.keys }.flatten.uniq.sort
    # remove non expt_inputs if necessary
    if options[:only_expt_inputs]
      input_ids = input_ids & expt_meta['input_ids']
    end

    scores = {}
    ad_presence = {}
    training_set.each do |profile_id|
      account_input_ids = mappings_full_hash[profile_id].keys & input_ids
      scores[profile_id] = self.compute_param_prediction_score(account_input_ids, params)
      ad_presence[profile_id] = observations_hash[profile_id] && observations_hash[profile_id] > 0
    end

    accuracies = {}
    scores.values.compact.uniq.sort.each do |threshold|
      accuracies[threshold] = self.compute_accuracy(scores, ad_presence, threshold)
    end
    best_threshold = accuracies.max[0]
    return best_threshold
  end

  def self.compute_param_prediction_score(account_input_ids, params)
    return account_input_ids.map { |id| params[id] }.compact.sum
  end

  def self.compute_accuracy(scores, ad_presence, threshold) tp = fp = tn = fn = 0
    scores.each do |profile_id, score|
      if threshold > 0
        # we predict we should see the ad
        if ad_presence[profile_id]
          # we see it
          tp += 1
        else
          fp += 1
        end
      else
        if ad_presence[profile_id]
          fn += 1
        else
          # we don't see the ad
          tn += 1
        end
      end
    end
    return nil if scores.count == 0
    return (tp + tn) / (tp + fp + tn + fn).to_f
  end




























  def self.evaluate(expt_id, options={})
    default_options = {
      :output_ids        => :all,  # :all or an array of output_ids, used mainly when
                                   # distributing the computations
      :only_expt_inputs  => false, # use it to remove inputs not in the expt inputs,
      :algorithms        => [:logit_simple,
                             :lm_simple,
                             :logit_full,
                             :lm_full,
                             :naive_bayes,
                             :set_intersection,
                             :set_intersection_3,],
      :guesses_key       => :guesses,
      :pvalue_key        => :pvalue,
      :pvalue_threshold  => :pvalue,
    }
    options.reverse_merge!(default_options)

    if options[:output_ids] == :all
      output_ids = Analytics::Observation.get_all_expt_outputs(expt_id)
    else
      output_ids = options[:output_ids]
    end

    @prepared_get_expt ||= Cassandra::Instance.session.prepare(
      "SELECT * FROM hypothesis WHERE expt_id=?;"
    )
    expt_id = expt_id.force_encoding('UTF-8')
    page = Cassandra::Instance.session.execute(
      @prepared_get_expt,
      { :arguments => [ expt_id ],
        :page_size => 1_000 }
    )
    guesses = {}
    loop do
      page.to_a.each do |row|
        next unless options[:output_ids] == :all || output_ids.include?(row['output_id'])
        next unless options[:algorithms].include?(row['algorithm_type'].to_sym)
        h = JSON.parse(row['algorithm_data']).symbolize_keys
        next if !h[options[:guesses_key]] || h[options[:guesses_key]].count == 0
        next unless h[options[:pvalue_key]]
        guesses[row['algorithm_type'].to_sym] ||= []
        guesses[row['algorithm_type'].to_sym].push(
          { :output_id => row['output_id'],
            options[:guesses_key] => h[options[:guesses_key]],
            options[:pvalue_key] => h[options[:pvalue_key]]}
        )
      end
      break if page.last_page?
      _retry = 0
      begin
        page = page.next_page
      rescue => e
        if (_retry = _retry + 1) && _retry < max_retry
          sleep 1
          retry
        end
        raise e
      end
    end

    guesses.map do |algorithm, hypothesis|
      pvalue_ids = hypothesis.map do |h|
        next if !h[options[:guesses_key]] || h[options[:guesses_key]].count == 0
        next unless h[options[:pvalue_key]]
        [h[:output_id], h[options[:pvalue_key]]]
      end.compact
      pvalues = pvalue_ids.map { |pid| pid[1] }
      low_pvalue_ids = []
      pvalues.each_with_index do |p, i|
        low_pvalue_ids.push(pvalue_ids[i][0]) if p < options[:pvalue_threshold]
      end
      corrected = self.correct_pvalues(pvalues)
      low_corrected_pvalue_ids = []
      corrected.each_with_index do |p, i|
        low_corrected_pvalue_ids.push(pvalue_ids[i][0]) if p < options[:pvalue_threshold]
      end
      [algorithm,
       {
        :pvalues                  => pvalues,
        :corrected_pvalues        => corrected,
        :number_of_guesses        => pvalues.count,
        :true_guesses             => low_pvalue_ids.count,
        :corrected_true_guesses   => low_corrected_pvalue_ids.count,
        :number_of_outputs        => output_ids.count,
        :low_pvalue_ids           => low_pvalue_ids,
        :low_corrected_pvalue_ids => low_corrected_pvalue_ids,
      }]
    end
  end

  def self.evaluate_ground_truth(expt_id, options={})
    default_options = {
      :mongo_exp => expt_id,
      :guesses_key => :guesses,
    }
    options.reverse_merge!(default_options)

    guesses = Analytics::Hypothesis.get_expt(expt_id)
    guesses = guesses.map do |g|
      r = JSON.parse(g['algorithm_data']).symbolize_keys
      r[:algorithm] = g['algorithm_type'].to_sym
      r[:output_id] = g['output_id']
      r
    end.group_by { |g| g[:algorithm] }

    guesses.map do |algorithm, hypothesis|
      total = tp = fp = tn = fn = 0
      hypothesis.each do |h|
        guess = h[options[:guesses_key]]
        truth = Analytics::Evaluation.get_truth(options[:mongo_exp], h[:output_id])
        next if truth == :no_truth
        total += 1
        # if guess.count == truth.count && (guess & truth).count == guess.count
        if (guess & truth).count > 0
          # right guess
          if guess.count > 0
            tp += 1
          else
            tn += 1
          end
        else
          if guess.count > 0
            fp += 1
          else
            fn += 1
          end
        end
      end
      precision = tp + fp == 0 ? 0 : tp.to_f / (tp + fp)
      recall    = tp + fn == 0 ? 0 : tp.to_f / (tp + fn)
      [algorithm,
       {
        :total             => total,
        :number_of_guesses => tp + fp,
        :tp                => tp,
        :fp                => fp,
        :tn                => tn,
        :fn                => fn,
        :precision         => precision,
        :recall            => recall,
      }]
    end
  end
end
