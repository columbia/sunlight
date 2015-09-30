class Analytics::Sparse::Regression
  def self.regression(expt_id, output_id, options={})
    default_options = {
      :familly          => :linear,  # :linear or :binomial
      :model            => :full,    # :full or :simple
      :profile_ids      => :all,     # :all or an array of profile_ids
      :data             => nil,      # potential precomputed data matrix
      :only_expt_inputs => false,    # use it to remove inputs not in the expt inputs,
                                     # like "Welcome to gmail" emails
      :max_combination_size => 5,    # max combination size
    }
    options.reverse_merge!(default_options)

    puts "#{options[:familly]} - #{options[:model]}".green

    data      = options[:data] || Analytics::API.ouput_data(expt_id, output_id)
    matrix    = Analytics::FormatData.matrix(expt_id, output_id,
                                          { :profile_ids      => options[:profile_ids],
                                            :model            => options[:model],
                                            :only_expt_inputs => options[:only_expt_inputs],
                                            :data             => data, })

    profile_ids   = data[:mappings].map { |d| d['profile_id'] }.uniq

    results = { :variables            => [],
                :lambda_1se           => [],
                :lambda_min           => [],
                :coefficients         => [],
                :prediction_threshold => 0 }

    if    options[:familly] == :linear
      displays = matrix[:log_displays]
      puts "0 sum in linear".red if displays.sum == 0
      return results if displays.sum == 0
    elsif options[:familly] == :binomial
      displays = matrix[:bool_displays]
      # glmnet doesn't do logit with only true values
      puts "0 sum in logit".red if displays.sum == 0
      puts "all 1 in logit".red if displays.sum == displays.count
      return results if displays.sum == 0 || displays.sum == displays.count
    end

    File.open('r_csv.csv', 'w') do |f|
      f.write 'displays, '
      f.puts matrix[:variables].join(", ")
      displays.each_with_index do |display, i|
        f.write "#{display}, "
        f.puts matrix[:matrix][i].join(', ')
      end
    end

    # remove previous result files
    ['vars.csv',
     '1se.csv',
     'min.csv'].each { |f_name| File.open(f_name, 'w') { |f| f.write '' } }
    R.eval <<EOF
      library("glmnet")
      setwd("#{Rails.root.to_s}")
      d <- read.csv("r_csv.csv")
      f <- as.formula(paste("~ 0 + ", paste(names(d)[#{options[:model] == :simple ? 3 : 4}:dim(d)[2]], collapse= " + ")))
      data <- model.matrix(f, data=d, sparse=TRUE)

      rm(fit)
      fit <- cv.glmnet(data, d$displays, intercept=FALSE, alpha=1#{options[:familly] == :binomial ? ', family="binomial", type.measure="class"' : ''})
      write.csv(as.vector(rownames(coef(fit,s=0))), file = "vars.csv", row.names=FALSE)
      write.csv(as.vector(coef(fit,s=fit$lambda.1se)), file = "1se.csv", row.names=FALSE)
      write.csv(as.vector(coef(fit,s=fit$lambda.min)), file = "min.csv", row.names=FALSE)
EOF

    begin
      vars = File.open('vars.csv') { |f| f.read }.split("\n")[1..-1].map { |e| e[1..-2] }
      results[:variables] = [vars[0]] +
                            vars[1..-1].map { |e| "#{e[0..1]}#{matrix[:h_to_inputs][e[2..-1]]}" }
      results[:lambda_min] = File.open('min.csv') { |f| f.read }
                                 .split("\n")[1..-1].map { |n| n.to_f }
      results[:lambda_1se] = File.open('1se.csv') { |f| f.read }
                                 .split("\n")[1..-1].map { |n| n.to_f }
      results[:coefficients] = results[:lambda_min]

      if options[:familly] == :binomial
        # for binomial algorithms the best threshold is the intercept
        results[:prediction_threshold] = results[:coefficients][0]
      elsif options[:familly] == :linear
        # for linear models we have to compute it
        results[:prediction_threshold] = self.compute_best_threshold(
          expt_id, output_id, data,
          profile_ids, results, options)
      else
        results[:prediction_threshold] = 0
      end
    rescue
      puts "ERROR exp: #{expt_id} ad: #{output_id}".red
    end
    return results
  end

  ######
  # implement the sparse phase protocol
  ######

  def self.ordered_inputs(algorithm_results)
    vars  = algorithm_results[:variables]
    coefs = algorithm_results[:coefficients]
    # ordered guesses to send to the filter function
    sorted_scores = vars.zip(coefs).sort { |a, b| a[1] <=> b[1] }.reverse
    sorted_candidates = []
    i = 0
    # select unique highest scores in order
    while sorted_scores.count > i && sorted_scores[i][1] > 0 do
      sorted_candidates = (sorted_candidates + [sorted_scores[i][0][2..-1]]).uniq
      i += 1
    end
    return sorted_candidates
  end

  def self.predict_output_presence(algorithm_results, inputs_in_profile)
    return false if !algorithm_results[:prediction_threshold]
    params = self.compute_params(algorithm_results)
    score = self.score_profile(inputs_in_profile, params)
    return score >= algorithm_results[:prediction_threshold]
  end

  def self.targeting_present?(algorithm_results)
    self.ordered_inputs(algorithm_results).count > 0
  end

  # params must be a hash of { input_id => float param }
  def self.compute_params(algorithm_results)
    params = algorithm_results[:variables].zip(algorithm_results[:coefficients])
    relevant_coefs = params.select { |pair| !!pair[0].match(/^(AE|PE).*/) }
                           .map { |pair| [pair[0][2..-1], pair[1]] }
    relevant_coefs = Hash[relevant_coefs]
    params.each do |pair|
      name = pair[0][2..-1]
      if !!pair[0].match(/^CE.*/) && (!relevant_coefs[name] || relevant_coefs[name] == 0)
        relevant_coefs[name] = pair[1]
      end
    end
    return relevant_coefs
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

    params = self.compute_params(algorithm_results)
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
