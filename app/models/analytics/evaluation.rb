class Analytics::Evaluation
  def self.evaluate(expt_id, options={})
    default_options = {
      :output_ids          => :all,  # :all or an array of output_ids, used mainly when
                                     # distributing the computations
      :profile_percentages => [1],   # used to evaluate the effect of growng the number
                                     # of accounts. [0.1, 0.5, 1] means we will run
                                     # 3 times, on 10%, 50% and all the accounts available
      :only_expt_inputs    => false, # use it to remove inputs not in the expt inputs,
      :training_percent    => 0.6,   # we will use training_percent * profiles to train,
                                     # (1 - training_percent) to test
      :hypothesis_computed => false,
      :store_results       => false,
      :algorithms          => [:logit_simple,
                               :lm_simple,
                               :logit_full,
                               :lm_full,
                               :naive_bayes,
                               :set_intersection,
                               :set_intersection_3,],
      :pvalue_threshold    => 0.01,  # when pvalue < pvalue_threshold we consider it a
                                     # true positive
      :guesses_key => :guesses,
      :pvalue_key  => :pvalue,
    }
    options.reverse_merge!(default_options)

    if options[:output_ids] == :all
      output_ids = Analytics::Observation.get_all_expt_outputs(expt_id)
    else
      output_ids = options[:output_ids]
    end

    if options[:hypothesis_computed]
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
    else
      guesses = []
      output_ids.each do |output_id|
        # TODO precompute training_set and testing_set
        guesses += Analytics::Analysis.analyse_with_pvalues(
          expt_id, output_id, options
        ).map do |algorithm, result|
          result[:algorithm] = algorithm
          result[:output_id] = output_id
          result
        end
      end
      guesses.group_by { |g| g[:algorithm] }
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

  def self.correct_pvalues(pvalues, options={})
    default_options = {
      :correction_method => :BY,  # https://stat.ethz.ch/R-manual/R-devel/library/stats/html/p.adjust.html
                                  # BY for average soft control
                                  # holm for full hard penalty
    }
    options.reverse_merge!(default_options)

    return [] if pvalues.count == 0

    File.open('pvals.csv', 'w') do |f|
      f.puts '"pvalues"'
      pvalues.each { |pval| f.puts pval }
    end

    R.eval <<EOF
    rm(r)
    d <- read.csv("pvals.csv")
    r <- p.adjust(d$pvalues, method="#{options[:correction_method].to_s}")
    write.csv(r, file = "pvals.csv", row.names=FALSE)
EOF

    File.open('pvals.csv', 'r') { |f| f.read }.split("\n")[1..-1].map(&:to_f)
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
        truth = self.get_truth(options[:mongo_exp], h[:output_id])
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

  def self.get_truth(exp_name, output_id)
    Mongoid.with_tenant(exp_name) do
      signature_hash = Digest::MD5.base64digest(output_id)
      cluster = SnapshotCluster.where(sig_id_hash: signature_hash).first
      truth = cluster.ground_truth_sig_ids rescue :no_truth
      return :no_truth if truth == :no_truth || !truth
      truth
    end
  end
end
