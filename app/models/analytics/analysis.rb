class Analytics::Analysis
  # Used to run all relevant algorithms. #
  def self.run_analysis(expt_id, output_id, options={})
    default_options = {
      :algorithms       => [],   # see analyse
      :only_expt_inputs => false,
      :store_results    => false,
      :profile_ids      => :all, # :all or an array of profile_ids
      :parameters       => {},
      :max_combination_size => 5,        # max combination size
    }
    options.reverse_merge!(default_options)
    results = {}
    options[:algorithms].each do |algo|
      algrorithm_options = {
        :only_expt_inputs => options[:only_expt_inputs],
        :profile_ids => options[:profile_ids]
      }
      if options[:parameters][algo]
        algrorithm_options[:parameters] = options[:parameters][algo]
      end
      case algo
      when :logit_simple
        result = Analytics::Sparse::Regression.logit_simple(
          expt_id,
          output_id,
          algrorithm_options
        )
      when :lm_full
        result = Analytics::Sparse::Regression.lm_full(
          expt_id,
          output_id,
          algrorithm_options
        )
      when :staged_logit_simple
        algrorithm_options.merge!(
          :model => :simple,
          :familly => :binomial,
        )
        result = Analytics::Regression.regression_glmnet(
          expt_id,
          output_id,
          algrorithm_options
        )
        result[:guesses] = result[:filtered_logit_simple_guesses]
      when :staged_lm_full
        algrorithm_options.merge!(
          :model => :full,
          :familly => :linear,
        )
        result = Analytics::Regression.regression_glmnet(
          expt_id,
          output_id,
          algrorithm_options
        )
        result[:guesses] = result[:filtered_lm_full_guesses]
      when :sparse_lm_full
        algrorithm_options.merge!(
          :model => :full,
          :sparse_familly => :linear,
          :regular_familly => :linear,
        )
        result = Analytics::SparseRegression.regression_glmnet(
          expt_id,
          output_id,
          algrorithm_options
        )
      when :sparse_logit_simple
        algrorithm_options.merge!(
          :model => :simple,
          :sparse_familly => :binomial,
          :regular_familly => :binomial,
        )
        result = Analytics::SparseRegression.regression_glmnet(
          expt_id,
          output_id,
          algrorithm_options
        )
      when :naive_bayes
        result = Analytics::NaiveBayes.naive_bayes(
          expt_id,
          output_id,
          algrorithm_options
        )
      when :set_intersection
        result = Analytics::SetIntersection.set_intersection(
          expt_id,
          output_id,
          algrorithm_options
        )
      when :set_intersection_3
        algrorithm_options.merge!(
          :parameters => { :max_combination_size => 3, :threshold => 0.99 }
        )
        result = Analytics::SetIntersection.set_intersection(
          expt_id,
          output_id,
          algrorithm_options,
        )
      end
      result[:likelihood] = self.likelihood(expt_id, output_id, result[:guesses], options)
      results[algo] = result
      if options[:store_results]
        Analytics::Hypothesis.add(expt_id, output_id, algo, result[:guesses], [], nil, result)
      end
    end
    results
  end

  def self.analyse_with_pvalues(expt_id, output_id, options={})
    default_options = {
      :only_expt_inputs => false, # use it to remove inputs not in the expt inputs,
      :store_results    => false,
      :data             => nil,   # potentialy pre-fetched cassandra data
      :algorithms       => [:logit_simple,
                            :lm_simple,
                            :logit_full,
                            :lm_full,
                            :naive_bayes,
                            :set_intersection,],
     :training_percent  => 0.7,   # we will use training_percent profiles to train,
                                  # (1 - training_percent) to test
     :training_set      => nil,
     :testing_set       => nil,
    }
    options.reverse_merge!(default_options)

    data = options[:data] || Analytics::API.ouput_data(expt_id, output_id)
    if !options[:training_set] || !options[:testing_set]
      profile_ids   = data[:mappings].map { |d| d['profile_id'] }.uniq
      training_size = (profile_ids.count.to_f * options[:training_percent]).ceil
      training_set, testing_set = profile_ids.shuffle.each_slice(training_size).to_a
    end
    analyse_options = {
      :async            => false,
      :algorithms       => options[:algorithms],  # see function comment
      :only_expt_inputs => options[:only_expt_inputs],
      :store_results    => false,
      :data             => data,
      :profile_ids      => training_set,
    }
    results = self.run_analysis(expt_id, output_id, analyse_options)
    pvalues_options = { :data => data,
                        :only_expt_inputs => options[:only_expt_inputs], }
    results.each do |algorithm, result|
      results[algorithm][:precision_pvalue] = self.pvalue(expt_id,
                                                output_id,
                                                result[:guesses],
                                                testing_set,
                                                pvalues_options)
      likelihood_options = {
        :only_expt_inputs => options[:only_expt_inputs],
        :profile_ids      => testing_set,
      }
      results[algorithm][:pvalue] = self.likelihood(expt_id,
                                                    output_id,
                                                    result[:guesses],
                                                    likelihood_options)
      results[algorithm][:training_set] = training_set
      results[algorithm][:testing_set] = testing_set

      params =
        begin
          if [:lm_full, :lm_simple, :logit_full, :logit_simple].include?(algorithm)
            results[algorithm][:variables].each_with_index.map do |x, i|
              next unless x[0..1] == "PE" || x[0..1] == "AE"
              [x[2..-1], results[algorithm][:lambda_1se][i]]
            end.compact
          elsif [:staged_logit_simple].include?(algorithm)
            vars = results[algorithm][:filtered_logit_simple_data][:variables]
            vars.each_with_index.map do |x, i|
              next unless x[0..1] == "PE" || x[0..1] == "AE" ||
                (x[0..1] == "CE" && !vars.include?("PE#{x[2..-1]}"))
              [x[2..-1], results[algorithm][:filtered_logit_simple_data][:coefficients][i]]
            end.compact
          elsif [:staged_lm_full].include?(algorithm)
            vars = results[algorithm][:filtered_lm_full_data][:variables]
            vars.each_with_index.map do |x, i|
              next unless x[0..1] == "PE" || x[0..1] == "AE" ||
                (x[0..1] == "CE" && !vars.include?("PE#{x[2..-1]}"))
              [x[2..-1], results[algorithm][:filtered_lm_full_data][:coefficients][i]]
            end.compact
          elsif [:sparse_lm_full, :sparse_logit_simple].include?(algorithm)
            vars = results[algorithm][:variables] || []
            vars.each_with_index.map do |x, i|
              next unless x[0..1] == "PE" || x[0..1] == "AE" ||
                (x[0..1] == "CE" && !vars.include?("PE#{x[2..-1]}"))
              [x[2..-1], results[algorithm][:variable_coefs][i]]
            end.compact
          elsif [:naive_bayes].include?(algorithm)
            results[algorithm][:scores]
          elsif [:set_intersection, :set_intersection_3].include?(algorithm)
            guesses = results[algorithm][:guesses]
            guesses.zip Array.new(guesses.count, 1)
          else
          end
        rescue
          []
        end
      results[algorithm][:predictions] = Analytics::EvaluationPrediction.evaluate_predictions(
        expt_id,
        algorithm,
        output_id,
        training_set,
        testing_set,
        result[:guesses],
        Hash[params])
      if options[:store_results]
        Analytics::Hypothesis.add(expt_id, output_id, algorithm,
                                  result[:guesses],
                                  [results[algorithm][:pvalue]],
                                  results[algorithm][:pvalue],
                                  results[algorithm])
      end
    end
    results
  end

  def self.pvalue(expt_id, output_id, guesses, testing_set, options={})
    default_options = {
      :data        => nil,   # potentialy pre-fetched cassandra data
      :hyper_distr => true,
    }
    options.reverse_merge!(default_options)

    return nil if guesses.count == 0

    data = options[:data] || Analytics::API.ouput_data(expt_id, output_id)
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

    profiles_count = testing_set.count
    profiles_w_ad = observations_hash.select { |profile_id, displays| displays > 0 }.count
    profiles_wo_ad = profiles_count - profiles_w_ad
    p_random = profiles_w_ad / profiles_count.to_f

    # right_guesses = total_guesses = 0
    right_guesses = wrong_guesses = total_guesses = 0
    testing_set.each do |profile_id|
      if (mappings_full_hash[profile_id].keys & guesses).count > 0
        # there is at least one input guessed, we predict we should see the ad
        total_guesses += 1
        if observations_hash[profile_id] && observations_hash[profile_id] > 0
          # we do see the ad
          right_guesses += 1
        else
          wrong_guesses += 1
        end
      end
    end

    if options[:hyper_distr]
      R.eval "pval <- phyper(#{right_guesses-1}, #{profiles_w_ad}, #{profiles_wo_ad}, #{total_guesses}, lower.tail=FALSE,log.p=FALSE)"
    else
      R.eval <<EOF
    r <- binom.test(c(#{right_guesses},#{wrong_guesses}), p=#{p_random}, alternative=c("greater"), conf.level=0.95)
    pval <- r$p.value
EOF
    end
    return R.pval
  end

  def self.pvalue_accuracy(expt_id, output_id, guesses, testing_set, options={})
    default_options = {
      :data                 => nil,   # potentialy pre-fetched cassandra data
    }
    options.reverse_merge!(default_options)

    return nil if guesses.count == 0

    data = options[:data] || Analytics::API.ouput_data(expt_id, output_id)
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

    right_guesses = wrong_guesses = 0
    testing_set.each do |profile_id|
      if (mappings_full_hash[profile_id].keys & guesses).count > 0
        # there is at least one input guessed, we predict we should see the ad
        if observations_hash[profile_id] && observations_hash[profile_id] > 0
          # we do see the ad
          right_guesses += 1
        else
          wrong_guesses += 1
        end
      else
        # no guess in account, predict no
        if observations_hash[profile_id] && observations_hash[profile_id] > 0
          # we still see the ad
          wrong_guesses += 1
        else
          right_guesses += 1
        end
      end
    end

    R.eval <<EOF
    r <- binom.test(c(#{right_guesses},#{wrong_guesses}), p=0.5, alternative=c("greater"), conf.level=0.95)
    pval <- r$p.value
EOF
    return R.pval
  end

  def self.likelihood(expt_id, output_id, guesses, options={})
    default_options = {
      :data             => nil,   # potentialy pre-fetched cassandra data
      :only_expt_inputs => false,
      :profile_ids      => :all, # :all or an array of profile_ids
    }
    options.reverse_merge!(default_options)

    return nil if guesses.count == 0

    data = options[:data] || Analytics::API.ouput_data(expt_id, output_id)
    mappings     = data[:mappings]
    observations = data[:observations]
    # mappings_hash full and no uncontroller_vars
    # is a hash of { profile_id => input_id => #displays }
    mappings_full_hash = Analytics::FormatData.hash_from_cassandra_rows(
      mappings,
      [],
      :model => :full,
      :profile_ids => options[:profile_ids],
      :hash_inputs => false
    )
    # observations_hash simple and no uncontroller_vars
    # is a hash of { profile_id => #displays }
    observations_hash = Analytics::FormatData.hash_from_cassandra_rows(
      observations,
      [],
      :model => :simple,
      :profile_ids => options[:profile_ids],
      :hash_inputs => false
    )

    profiles_with_output_n = observations_hash.select do |profile_id, displays|
      displays > 0 &&
      (options[:profile_ids] == :all || options[:profile_ids].include?(profile_id))
    end.keys.compact.uniq.count

    profiles_with_output_and_input_n = observations_hash.select do |profile_id, displays|
      # sees the ad and has only one guessed input in the profile
      displays > 0 &&
      (options[:profile_ids] == :all || options[:profile_ids].include?(profile_id)) &&
      mappings_full_hash[profile_id] &&
      (mappings_full_hash[profile_id].keys & guesses).count > 0
   end.keys.compact.uniq.count

   if options[:only_expt_inputs]
     input_n = data[:expt_meta]["input_ids"].uniq.count
   else
     input_n = mappings_full_hash.map { |profile, d| d.keys }
                                 .flatten.uniq.count
   end

   return Analytics::Likelihood.confidence_level(profiles_with_output_n,
                                      profiles_with_output_and_input_n,
                                      guesses.count,
                                      data[:expt_meta]['profiles_percent_with_inputs'],
                                      input_n)
  end

  def self.greedy_filter(expt_id,
                         output_id,
                         ordered_inputs,
                         options={})
    default_options = {
      :profile_ids          => :all,  # :all or an array of profile_ids
      :only_expt_inputs     => false,
      :data                 => nil,   # potentialy pre-fetched cassandra data
      :max_combination_size => 5,     # max combination size
      :pvalue_threshold     => 0.05,  # the max pvalue on profile ids. If it is above that
                                      # we return non targeted
    }
    options.reverse_merge!(default_options)

    data = options[:data] || Analytics::API.ouput_data(expt_id, output_id)
    mappings     = data[:mappings]
    observations = data[:observations]
    # mappings_hash full and no uncontroller_vars
    # is a hash of { profile_id => input_id => #displays }
    mappings_full_hash = Analytics::FormatData.hash_from_cassandra_rows(
      mappings,
      [],
      :model => :full,
      :profile_ids => options[:profile_ids],
      :hash_inputs => false,
    )
    # observations_hash simple and no uncontroller_vars
    # is a hash of { profile_id => #displays }
    observations_hash = Analytics::FormatData.hash_from_cassandra_rows(
      observations,
      [],
      :model => :simple,
      :profile_ids => options[:profile_ids],
      :hash_inputs => false,
    )
    Analytics::Utils.flush_cache

    sorted_candidates = ordered_inputs[0..options[:max_combination_size]]

    candidates_stats = {}
    sorted_candidates.count.times do |j|
      candidates_stats[j] = {
        :tp => 0,
        :fp => 0,
        :tn => 0,
        :fn => 0,
      }
    end

    # NOTE mappings_full_hash should already have the input_ids filtered out
    profile_ids = mappings_full_hash.keys.uniq

    profile_ids.each do |profile_id|
      profile_input_ids = mappings_full_hash[profile_id].keys.uniq
      sorted_candidates.count.times do |j|
        if (profile_input_ids & sorted_candidates[0..j]).count > 0
          # we would predict yes
          if observations_hash[profile_id] && observations_hash[profile_id] > 0
            # we do see it
            candidates_stats[j][:tp] += 1
          else
            candidates_stats[j][:fp] += 1
          end
        else
          # we would predict no
          if observations_hash[profile_id] && observations_hash[profile_id] > 0
            # we still see it
            candidates_stats[j][:fn] += 1
          else
            candidates_stats[j][:tn] += 1
          end
        end
      end
    end

    indices = candidates_stats.map do |k, v|
      tot = v[:tp] + v[:fp] + v[:tn] + v[:fn]
      acc = tot == 0 ? 0 : (v[:tp] + v[:tn]) / tot.to_f
      [k, acc]
    end
    # get the indice with max accuracy
    max_indice = indices.sort { |x, y| x.reverse <=> y.reverse }.reverse.first.first
    candidates = sorted_candidates[0..max_indice]

    # now we compute the pvalue of the training set
    profiles_with_output_n = observations_hash.select do |profile_id, displays|
      displays > 0 &&
      (options[:profile_ids] == :all || options[:profile_ids].include?(profile_id))
    end.keys.compact.uniq.count

    profiles_with_output_and_input_n = observations_hash.select do |profile_id, displays|
      # sees the ad and has only one guessed input in the profile
      displays > 0 &&
      (options[:profile_ids] == :all || options[:profile_ids].include?(profile_id)) &&
      mappings_full_hash[profile_id] &&
      (mappings_full_hash[profile_id].keys & candidates).count > 0
   end.keys.compact.uniq.count

   if options[:only_expt_inputs]
     input_n = data[:expt_meta]["input_ids"].uniq.count
   else
     input_n = mappings_full_hash.map { |profile, d| d.keys }
                                 .flatten.uniq.count
   end
   pvalue = Analytics::Likelihood.confidence_level(
     profiles_with_output_n,
     profiles_with_output_and_input_n,
     candidates.count,
     data[:expt_meta]['profiles_percent_with_inputs'],
     input_n)

    return [] if pvalue > options[:pvalue_threshold]
    return candidates
  end

  def self.analyse_filter(expt_id,
                          output_id,
                          variables,
                          coefficients,
                          options={})
    default_options = {
      :profile_ids          => :all,  # :all or an array of profile_ids
      :data                 => nil,   # potentialy pre-fetched cassandra data
      :max_combination_size => 5,     # max combination size
    }
    options.reverse_merge!(default_options)

    data = options[:data] || Analytics::API.ouput_data(expt_id, output_id)
    mappings     = data[:mappings]
    observations = data[:observations]
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
    Analytics::Utils.flush_cache

    sorted_scores = variables.zip(coefficients).sort { |a, b| a[1] <=> b[1] }.reverse
    sorted_candidates = []
    i = 0
    # select 5 unique highest scores in order
    while sorted_scores.count > i &&
          sorted_candidates.count < options[:max_combination_size] &&
          sorted_scores[i][1] > 0 do
      sorted_candidates = (sorted_candidates + [sorted_scores[i][0]]).uniq
      i += 1
    end

    return [] if sorted_candidates.count == 0

    candidates_stats = {}
    sorted_candidates.count.times do |j|
      candidates_stats[j] = {
        :tp => 0,
        :fp => 0,
        :tn => 0,
        :fn => 0,
      }
    end

    # NOTE mappings_full_hash should already have the input_ids filtered out
    # if options[:profile_ids] == :all
      profile_ids = mappings_full_hash.keys.uniq
    # else
      # profile_ids = options[:profile_ids]
    # end
    profile_ids.each do |profile_id|
      profile_input_ids = mappings_full_hash[profile_id].keys.uniq
      sorted_candidates.count.times do |j|
        if (profile_input_ids & sorted_candidates[0..j]).count > 0
          # we would predict yes
          if observations_hash[profile_id] && observations_hash[profile_id] > 0
            # we do see it
            candidates_stats[j][:tp] += 1
          else
            candidates_stats[j][:fp] += 1
          end
        else
          # we would predict no
          if observations_hash[profile_id] && observations_hash[profile_id] > 0
            # we still see it
            candidates_stats[j][:fn] += 1
          else
            candidates_stats[j][:tn] += 1
          end
        end
      end
    end

    indices = candidates_stats.map do |k, v|
      prec = (v[:tp] + v[:fp]) == 0 ? 0 : (v[:tp].to_f / (v[:tp] + v[:fp]))
      rec = (v[:tp] + v[:fn]) == 0 ? 0 : (v[:tp].to_f / (v[:tp] + v[:fn]))
      p_rand = profile_ids.select do |profile_id|
        observations_hash[profile_id] && observations_hash[profile_id] > 0
      end.count.to_f / profile_ids.count
      predictions_n = v[:tp] + v[:fp]
      random_2se = p_rand + 2 * Math.sqrt(p_rand * (1 - p_rand) / predictions_n)
      [k, prec, rec, random_2se]
    end
    indices = indices.select do |a|  # select the one with prec > 2se
      a[1] > a[3]
    end

    return [] if indices.count == 0
    max_recall = indices.map { |a| a[2] }.max
    # we want max precision for best recall
    best_index = indices.select { |a| a[2] == max_recall }.max_by { |a| a[1] }
    return [] if best_index[1] == 0
    return sorted_candidates[0..best_index[0]]
  end

  def self.analyse_filter_regression(expt_id,
                                     output_id,
                                     variables,
                                     coefficients,
                                     options={})
    default_options = {
      :familly              => :linear,  # :linear or :binomial
      :model                => :full,    # :full or :simple
      :profile_ids          => :all,     # :all or an array of profile_ids
      :only_expt_inputs     => false,    # use it to remove inputs not in the expt inputs,
                                         # like "Welcome to gmail" emails
      :max_combination_size => 5,        # max combination size
      :coef_pvalue          => 0.01,
    }
    options.reverse_merge!(default_options)

    data = Analytics::Regression.matrix(expt_id, output_id,
                       { :profile_ids      => options[:profile_ids],
                         :model            => options[:model],
                         :only_expt_inputs => options[:only_expt_inputs], })

    sorted_candidates = variables.zip(coefficients).sort { |a, b| a[1] <=> b[1] }.reverse
    candidates = sorted_candidates[0...options[:max_combination_size]]
                   .select { |c| c[1] > 0 }
                   .map(&:first)
                   .uniq

    results = {
      :guesses       => [],
      :variables     => [],
      :coefficients  => [],
    }

    if    options[:familly] == :linear
      displays = data[:log_displays]
      return results if displays.sum == 0
    elsif options[:familly] == :binomial
      displays = data[:bool_displays]
      # glmnet doesn't do logit with only true values
      return results if displays.sum == 0 || displays.sum == displays.count
    end

    File.open('r_csv.csv', 'w') do |f|
      f.write 'displays, '
      f.puts data[:variables].join(", ")
      displays.each_with_index do |display, i|
        f.write "#{display}, "
        f.puts data[:matrix][i].join(', ')
      end
    end

    R.candidates = candidates
    R.eval <<EOF
      library("glmnet")
      setwd("#{Rails.root.to_s}")
      d <- read.csv("r_csv.csv")

      non_sparse_formula <- as.formula(paste("displays ~ ", paste(candidates, collapse=" + ")))
      non_sparse_formula
      rm(r)
      r <- #{
        if options[:familly] == :binomial
          "glm(formula = non_sparse_formula, family = binomial, data = d)"
        elsif options[:familly] == :linear
          "lm(formula = non_sparse_formula, data = d)"
        end
      }
      rm(coefs)
      rm(stderr)
      rm(pvals)
      coefs  <- summary(r)$coef[,"Estimate"]
      stderr <- summary(r)$coef[,"Std. Error"]
      pvals  <- summary(r)$coef[,"Pr(>|#{options[:familly] == :linear ? "t" : "z"}|)"]
      var_names <- names(pvals)
      rm(significant_indices)
      rm(significant_vars)
      rm(significant_coefs)
      rm(significant_stderr)
      rm(significant_pvals)
      significant_indices <- which(pvals <= #{options[:coef_pvalue]})
      significant_vars  <- as.vector(sapply(significant_indices, function(x) var_names[x]))
      significant_coefs <- as.vector(sapply(significant_indices, function(x) coefs[x]))
      significant_stderr <- as.vector(sapply(significant_indices, function(x) stderr[x]))
      significant_pvals <- as.vector(sapply(significant_indices, function(x) pvals[x]))
EOF

    begin
      vars  = R.significant_vars
      vars  = [vars] unless vars.kind_of?(Array)
      coefs = R.significant_coefs
      coefs = [coefs] unless coefs.kind_of?(Array)
      stderr = R.significant_stderr
      stderr = [stderr] unless stderr.kind_of?(Array)
      pvals = R.significant_pvals
      pvals = [pvals] unless pvals.kind_of?(Array)
      guesses = self.analyse_regression_filter_results(vars, coefs, stderr)
      guesses = guesses.select { |v| !v.downcase.include?("intercept") }
                       .map { |v| v[2..-1] }
                       .compact.uniq
      guesses = guesses.map { |e| data[:h_to_inputs][e] }
    rescue
      puts "ERROR sparse exp: #{expt_id} ad: #{output_id}"
    end
    return {
      :guesses       => (guesses || []),
      :variables     => (vars || []).map do |e|
        if e.downcase.include?('intercept')
          e
        else
          "#{e[0..1]}#{data[:h_to_inputs][e[2..-1]]}"
        end
      end,
      :coefficients  => (coefs || []),
    }
  end

  def self.analyse_regression_filter_results(variables, coefficients, standard_errors)
    # find coefficients that are bigger than 0 + 2 std_err and
    # that are bigger than the intercept coef
    intercept_coef = 0
    variables.each_with_index do |coef, i|
      intercept_coef = coefficients[i] if coef.downcase.include?("intercept")
    end
     # .select { |coeff, i| coeff - 2 * standard_errors[i] > 0 && coeff >= intercept_coef }
    coefficients.each_with_index
     .select { |coeff, i| coeff > 0 }
     .map { |coeff, i| variables[i] }
  end
end
