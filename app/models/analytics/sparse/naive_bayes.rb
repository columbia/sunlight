class Analytics::Sparse::NaiveBayes
  def self.analyse(expt_id, output_id, options={})
    default_options = {
      :profile_ids      => :all,     # :all or an array of profile_ids
      :data             => nil,      # potential precomputed data matrix
      :only_expt_inputs => false,    # use it to remove inputs not in the expt inputs,
                                     # like "Welcome to gmail" emails
      :parameters       => { :pin => 0.02, :pout => 0.0003, :prandom => 0.01 },
      :max_combination_size => 5,    # max combination size
    }
    options.reverse_merge!(default_options)

    data         = options[:data] || Analytics::API.ouput_data(expt_id, output_id)
    expt_meta    = data[:expt_meta]
    mappings     = data[:mappings]
    observations = data[:observations]

    Analytics::Utils.flush_cache
    # mappings_hash full and no uncontroller_vars
    # is a hash of { profile_id => input_id => #displays }
    mappings_full_hash = Analytics::FormatData.hash_from_cassandra_rows(
      mappings,
      [],
      :model => :full,
      :profile_ids => options[:profile_ids]
    )
    # observations_hash simple and no uncontroller_vars
    # is a hash of { profile_id => #displays }
    observations_hash = Analytics::FormatData.hash_from_cassandra_rows(
      observations,
      [],
      :model => :simple,
      :profile_ids => options[:profile_ids]
    )
    cache = Analytics::Utils.get_cache
    Analytics::Utils.flush_cache

    input_ids = mappings_full_hash.map { |_, v| v.keys }.flatten.uniq.sort
    # remove non expt_inputs if necessary
    if options[:only_expt_inputs]
      input_ids = input_ids.select do |input_id|
        expt_meta['input_ids'].include?(cache[input_id])
      end
    end

    profile_ids = mappings_full_hash.keys.uniq
    profiles_w_output = profile_ids.select do |profile_id|
      observations_hash[profile_id] && observations_hash[profile_id] > 0
    end

    _scores = input_ids.map do |input_id|
      [input_id, self.proba_output_targets_input(options[:parameters],
                                                 profile_ids,
                                                 profiles_w_output,
                                                 mappings_full_hash,
                                                 input_id)]
    end
    scores = _scores.push(["", self.proba_output_targets_void(options[:parameters],
                                                              profile_ids,
                                                              profiles_w_output)])
    tot = scores.reduce(0) { |sum, e| sum + e[1] }
    results = {}
    results[:scores] = Hash[scores.map do |s|
      if tot > 0
        s[0] == "" ? [s[0], s[1] / tot] : [cache[s[0]], s[1] / tot]
      else
        s[0] == "" ? ["", 1] : [s[0], 0]
      end
    end]

    results[:best_threshold] = self.compute_best_threshold(expt_id, output_id, data,
                                                           profile_ids, results, options)

    return results
  end

  def self.proba_output_targets_input(parameters, profile_ids, profiles_w_output,
                                      mappings, input_id)

    profiles_n = profile_ids.count.to_f
    raise "Analytics::NaiveBayes 0 accounts selected" if profiles_n == 0

    profiles_w_input = profile_ids.select do |profile_id|
      mappings[profile_id] && mappings[profile_id].keys.include?(input_id)
    end
    profiles_w_input_w_output = profiles_w_input & profiles_w_output

    profiles_w_input          = profiles_w_input.count
    profiles_w_output         = profiles_w_output.count
    profiles_w_input_w_output = profiles_w_input_w_output.count

    profiles_w_input_wo_output  = profiles_w_input  - profiles_w_input_w_output
    profiles_wo_input_w_output  = profiles_w_output - profiles_w_input_w_output
    profiles_wo_input_wo_output = profiles_n - profiles_w_input - profiles_w_output + profiles_w_input_w_output

    if profiles_n > 100
      profiles_w_input_w_output   = profiles_w_input_w_output   * 100.0 / profiles_n
      profiles_w_input_wo_output  = profiles_w_input_wo_output  * 100.0 / profiles_n
      profiles_wo_input_w_output  = profiles_wo_input_w_output  * 100.0 / profiles_n
      profiles_wo_input_wo_output = profiles_wo_input_wo_output * 100.0 / profiles_n
    end
    p, q = parameters[:pin], parameters[:pout]
    p ** profiles_w_input_w_output * q ** profiles_wo_input_w_output * (1-p) ** profiles_w_input_wo_output * (1-q) ** profiles_wo_input_wo_output
  end

  def self.proba_output_targets_void(parameters, profile_ids, profiles_w_output)
    profiles_n = profile_ids.count.to_f
    profiles_w_output = profiles_w_output.count
    raise "Analytics::NaiveBayes 0 accounts selected" if profiles_n == 0

    profiles_wo_output = profiles_n - profiles_w_output
    if profiles_n > 0
      profiles_w_output  = profiles_w_output  * 100.0 / profiles_n
      profiles_wo_output = profiles_wo_output * 100.0 / profiles_n
    end
    prand = parameters[:prandom]
    prand ** profiles_w_output * (1-prand) ** profiles_wo_output
  end

  def self.ordered_inputs(algorithm_results)
    algorithm_results[:scores].sort_by { |k, v| v }
                              .reverse
                              .map(&:first)
                              .select { |x| x && x != "" }
  end

  def self.predict_output_presence(algorithm_results, inputs_in_profile)
    return false if !algorithm_results[:best_threshold]

    max_score = algorithm_results[:scores].values.select { |n| !n.to_f.nan? }.max
    max_key   = algorithm_results[:scores].select { |k,v| v == max_score }.keys.first
    return false if max_key == ""

    self.score_profile(inputs_in_profile, algorithm_results[:scores]) >= algorithm_results[:best_threshold]
  end

  def self.targeting_present?(algorithm_results)
    max_score = algorithm_results[:scores].values.select { |n| !n.to_f.nan? }.max
    max_key   = algorithm_results[:scores].select { |k,v| v == max_score }.keys.first
    max_key  != ""
  end

  # params must be a hash of { input_id => float param }
  def self.compute_best_threshold(expt_id,
                                  output_id,
                                  data,
                                  training_set,
                                  algorithm_results,
                                  options={})
    # compute scores for each account, and cross-validate to
    # pick threshold with best accuracy(? or ROC/AUC)
    default_options = { :only_expt_inputs => false, }
    options.reverse_merge!(default_options)

    expt_meta    = data[:expt_meta]
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

    params = algorithm_results[:scores]
    scores = {}
    ad_presence = {}
    training_set.each do |profile_id|
      account_input_ids = mappings_full_hash[profile_id].keys & input_ids
      scores[profile_id] = self.score_profile(account_input_ids, params)
      ad_presence[profile_id] = observations_hash[profile_id] && observations_hash[profile_id] > 0
    end

    accuracies = {}
    scores.values.compact.uniq.sort.each do |threshold|
      accuracies[threshold] = self.compute_accuracy(scores, ad_presence, threshold)
    end
    best_threshold = accuracies.max[0]
    return best_threshold
  end

  def self.score_profile(account_input_ids, params)
    account_input_ids.map { |input_id| params[input_id] }.compact.sum || 0
  end

  def self.compute_accuracy(scores, ad_presence, threshold)
    tp = fp = tn = fn = 0
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
end
