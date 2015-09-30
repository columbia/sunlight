class Analytics::Eval
  @algo_translate = {
    :logit_simple => :logit,
    :lm_full => :lm,
    :naive_bayes => :bayes,
    :set_intersection => :set_intersection,
  }
  def self.evaluate(expt_id, algorithms, options={})
    default_options = { :pvalue_threshold => 0.05 }
    options.reverse_merge! default_options

    self.stage1(expt_id, algorithms, options)
    self.low_pval_recall(expt_id, algorithms, options)
    self.pvalue_distribution(expt_id, :set_intersection, options)
  end

  def self.compare_scale(expt_id_small, expt_id_large, algorithm, options={})
    default_options = { :pvalue_threshold => 0.05 }
    options.reverse_merge! default_options

    pval_large = self.get_pvals(expt_id_large, algorithm, options)
    pval_small = self.get_pvals(expt_id_small, algorithm, options)
    # pval distr for different algos
    # for graphs
    range  = 9.times.map { |n| n+1 }
    points = 8.times.map { |i| range.map { |n| n / (10.0 ** (i+1)) } }.flatten.sort + [1.0]
    [:pval, :by, :holm].each do |corr|
      File.open("stages_pvalue_cross_comparison_distr_#{corr}_#{expt_id_small}_#{expt_id_large}.dat", 'w') do |f|
        f.puts "points #{expt_id_small} #{expt_id_large}"
        points.each do |point|
          small = pval_small[algorithm][corr].select { |p| p <= point }.count
          small_tot = pval_small[algorithm][corr].count.to_f
          large = pval_large[algorithm][corr].select { |p| p <= point }.count
          large_tot = pval_large[algorithm][corr].count.to_f
          f.puts "#{point} #{(small / small_tot).round(2)} #{(large / large_tot).round(2)}"
        end
      end
    end
  end
  def self.get_pvals(expt_id, algorithm, options)
    # get the data and compute the metrics
    @prepared_get_expt ||= Cassandra::Instance.session.prepare(
      "SELECT * FROM hypothesis WHERE expt_id=?;"
    )
    expt_id = expt_id.force_encoding('UTF-8')
    page = Cassandra::Instance.session.execute(
      @prepared_get_expt,
      { :arguments => [ expt_id ],
        :page_size => 1_000 }
    )
    _page = 0
    found     = {}
    loop do
      page.to_a.each do |row|
        # we are not interested in all algos
        algo = row['algorithm_type'].to_sym
        next unless algorithm == algo
        # we want only hypothesis with a prediction
        next unless row['input_ids'] && JSON.parse(row['input_ids']).compact.count > 0

        found[algo] ||= { :pval => [], :by => [], :holm => [] }

        pvalue = row['pvalue']
        by_pvalue = row['corr_by_pvalue']
        holm_pvalue = row['corr_holm_pvalue']

        found[algo][:pval] ||= []
        found[algo][:pval].push pvalue
        found[algo][:by] ||= []
        found[algo][:by].push by_pvalue
        found[algo][:holm] ||= []
        found[algo][:holm].push holm_pvalue
      end
      break if page.last_page?
      page = page.next_page
      puts (_page = (_page + 1)).to_s.red
    end

    return found
  end

  def self.pvalue_distribution(expt_id, algorithm, options)
    # get the data and compute the metrics
    @prepared_get_expt ||= Cassandra::Instance.session.prepare(
      "SELECT * FROM hypothesis WHERE expt_id=?;"
    )
    expt_id = expt_id.force_encoding('UTF-8')
    page = Cassandra::Instance.session.execute(
      @prepared_get_expt,
      { :arguments => [ expt_id ],
        :page_size => 1_000 }
    )

    _page = 0
    algo = algorithm
    pvalues_before = {}
    pvalues_after  = {}
    loop do
      page.to_a.each do |row|
        # we are not interested in all algos
        next unless row['algorithm_type'].to_sym == algorithm

        pvalues_before[algo] ||= { :pval => [] }
        pvalues_after[algo]  ||= { :pval => [] }

        pvalue_before, pvalue_after = JSON.parse(row['confidences'])
        pvalues_before[algo][:pval].push pvalue_before if pvalue_before
        pvalues_after[algo][:pval].push  pvalue_after  if pvalue_after
      end
      break if page.last_page?
      page = page.next_page
      puts (_page = (_page + 1)).to_s.red
    end

    pvalues                     = pvalues_before[algo][:pval]
    pvalues_before[algo][:by]   = Analytics::Evaluation.correct_pvalues(pvalues, :correction_method => :BY)
    pvalues_before[algo][:holm] = Analytics::Evaluation.correct_pvalues(pvalues, :correction_method => :holm)
    pvalues_before[algo][:bonferroni] = Analytics::Evaluation.correct_pvalues(pvalues, :correction_method => :bonferroni)
    pvalues                     = pvalues_after[algo][:pval]
    pvalues_after[algo][:by]    = Analytics::Evaluation.correct_pvalues(pvalues, :correction_method => :BY)
    pvalues_after[algo][:holm]  = Analytics::Evaluation.correct_pvalues(pvalues, :correction_method => :holm)
    pvalues_after[algo][:bonferroni]  = Analytics::Evaluation.correct_pvalues(pvalues, :correction_method => :bonferroni)

    # for graphs
    range  = 9.times.map { |n| n+1 }
    points = 8.times.map { |i| range.map { |n| n / (10.0 ** (i+1)) } }.flatten.sort + [1.0]

    [:pval, :by, :holm, :bonferroni].each do |corr|
      File.open("stages_pval_distr_absolute_#{corr}_#{expt_id}.dat", 'w') do |f|
        f.puts "points before_filter after_filter"
        points.each do |point|
          before_n = pvalues_before[algo][corr].select { |p| p <= point }.count
          after_n  = pvalues_after[algo][corr].select { |p| p <= point }.count
          f.puts "#{point} #{before_n} #{after_n}"
        end
      end
      File.open("stages_pval_distr_proportion_#{corr}_#{expt_id}.dat", 'w') do |f|
        f.puts "points before_filter after_filter"
        tot_before_n = pvalues_before[algo][corr].count.to_f
        tot_after_n  = pvalues_after[algo][corr].count.to_f
        points.each do |point|
          before_n = pvalues_before[algo][corr].select { |p| p <= point }.count
          after_n  = pvalues_after[algo][corr].select { |p| p <= point }.count
          f.puts "#{point} #{(before_n / tot_before_n).round(2)} #{(after_n / tot_after_n).round(2)}"
        end
      end
    end
  end

  def self.low_pval_recall(expt_id, algorithms, options)
    # get the data and compute the metrics
    @prepared_get_expt ||= Cassandra::Instance.session.prepare(
      "SELECT * FROM hypothesis WHERE expt_id=?;"
    )
    expt_id = expt_id.force_encoding('UTF-8')
    page = Cassandra::Instance.session.execute(
      @prepared_get_expt,
      { :arguments => [ expt_id ],
        :page_size => 1_000 }
    )

    _page = 0
    found     = {}
    pvals     = {}
    all_found = { :pval => [], :by => [], :holm => [] }
    loop do
      page.to_a.each do |row|
        # we are not interested in all algos
        algo = row['algorithm_type'].to_sym
        next unless algorithms.include?(algo)
        # we want only hypothesis with a prediction
        next unless row['input_ids'] && JSON.parse(row['input_ids']).compact.count > 0

        output_id = row['output_id']
        found[algo] ||= { :pval => [], :by => [], :holm => [] }
        pvals[algo] ||= { :pval => [], :by => [], :holm => [] }

        pvalue = row['pvalue']
        by_pvalue = row['corr_by_pvalue']
        holm_pvalue = row['corr_holm_pvalue']
        pvals[algo][:pval] ||= []
        pvals[algo][:pval].push pvalue
        pvals[algo][:by] ||= []
        pvals[algo][:by].push by_pvalue
        pvals[algo][:holm] ||= []
        pvals[algo][:holm].push holm_pvalue

        if pvalue && pvalue <= options[:pvalue_threshold]
          found[algo][:pval] ||= []
          found[algo][:pval].push output_id
          all_found[:pval].push output_id
        end
        if by_pvalue && by_pvalue <= options[:pvalue_threshold]
          found[algo][:by] ||= []
          found[algo][:by].push output_id
          all_found[:by].push output_id
        end
        if holm_pvalue && holm_pvalue <= options[:pvalue_threshold]
          found[algo][:holm] ||= []
          found[algo][:holm].push output_id
          all_found[:holm].push output_id
        end
      end
      break if page.last_page?
      page = page.next_page
      puts (_page = (_page + 1)).to_s.red
    end

    # pval recall
    File.open("stages_pvalue_recall_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      f.write "low_pvals"
      algorithms.each do |algo|
        f.write " #{(found[algo][:pval].uniq.count / all_found[:pval].uniq.count.to_f).round(2)}"
      end
      f.puts
      f.write "low_pvals_w/BY"
      algorithms.each do |algo|
        f.write " #{(found[algo][:by].uniq.count / all_found[:by].uniq.count.to_f).round(2)}"
      end
      f.puts
      f.write "low_pvals_w/Holm"
      algorithms.each do |algo|
        f.write " #{(found[algo][:holm].uniq.count / all_found[:holm].uniq.count.to_f).round(2)}"
      end
      f.puts
    end
    # pval distr for different algos
    # for graphs
    range  = 9.times.map { |n| n+1 }
    points = 8.times.map { |i| range.map { |n| n / (10.0 ** (i+1)) } }.flatten.sort + [1.0]
    [:pval, :holm].each do |corr|
      File.open("stages_pvalue_comparison_distr_#{corr}_#{expt_id}.dat", 'w') do |f|
        f.puts "points #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
        points.each do |point|
          algo_points = algorithms.map do |algo|
            pvals[algo][corr].select { |p| p <= point }.count
          end
          f.puts "#{point} #{algo_points.join(' ')}"
        end
      end
    end
  end

  def self.stage1(expt_id, algorithms, options)
    # get the data and compute the metrics
    @prepared_get_expt ||= Cassandra::Instance.session.prepare(
      "SELECT * FROM hypothesis WHERE expt_id=?;"
    )
    expt_id = expt_id.force_encoding('UTF-8')
    page = Cassandra::Instance.session.execute(
      @prepared_get_expt,
      { :arguments => [ expt_id ],
        :page_size => 1_000 }
    )

    # quartiles
    precision                   = {}
    recall                      = {}
    precision_after_filter      = {}
    recall_after_filter         = {}
    low_pval_precision          = {}
    low_pval_recall             = {}
    stage_1_predictions         = Hash.new(0)
    predictions                 = Hash.new(0)
    low_pvalue_predictions      = Hash.new(0)
    low_by_pvalue_predictions   = Hash.new(0)
    low_holm_pvalue_predictions = Hash.new(0)
    # for total precision/recall
    metrics_total_stage1        = {}
    metrics_total_after_filter  = {}
    metrics_total_low_pval      = {}

    _page = 0
    loop do
      page.to_a.each do |row|
        # we are not interested in all algos
        algo = row['algorithm_type'].to_sym
        next unless algorithms.include?(algo)
        # get the metrics we want
        h = JSON.parse(row['algorithm_data']).symbolize_keys

        sparse_class         = h[:pipeline]['sparse'].constantize
        results              = h[:results]['sparse']['results'].symbolize_keys
        metrics              = h[:results]['sparse']['accuracy']
        metrics_after_filter = h[:results]['filters'].last['accuracy']

        prec = rec = 0
        if metrics['tp'] + metrics['fp'] > 0
          prec = metrics['tp'] / (metrics['tp'] + metrics['fp']).to_f
        end
        if metrics['tp'] + metrics['fn'] > 0
          rec = metrics['tp'] / (metrics['tp'] + metrics['fn']).to_f
        end
        prec_after = rec_after = 0
        if metrics_after_filter['tp'] + metrics_after_filter['fp'] > 0
          prec_after = metrics_after_filter['tp'] /
                       (metrics_after_filter['tp'] + metrics_after_filter['fp']).to_f
        end
        if metrics_after_filter['tp'] + metrics_after_filter['fn'] > 0
          rec_after = metrics_after_filter['tp'] /
                      (metrics_after_filter['tp'] + metrics_after_filter['fn']).to_f
        end

        # for quartiles
        precision[algo]              ||= []
        recall[algo]                 ||= []
        precision_after_filter[algo] ||= []
        recall_after_filter[algo]    ||= []
        low_pval_precision[algo]     ||= { :pval => [], :by => [], :holm => [] }
        low_pval_recall[algo]        ||= { :pval => [], :by => [], :holm => [] }
        # for total precision/recall
        metrics_total_stage1[algo]       ||= { :tp => 0, :fp => 0, :tn => 0, :fn => 0 }
        metrics_total_after_filter[algo] ||= { :tp => 0, :fp => 0, :tn => 0, :fn => 0 }
        metrics_total_low_pval[algo]     ||= {
          :pval => { :tp => 0, :fp => 0, :tn => 0, :fn => 0 },
          :by   => { :tp => 0, :fp => 0, :tn => 0, :fn => 0 },
          :holm => { :tp => 0, :fp => 0, :tn => 0, :fn => 0 }
        }

        if sparse_class.targeting_present?(results)
          # we predict targeting at stage 1
          stage_1_predictions[algo] += 1

          precision[algo].push prec.round(2)
          recall[algo].push rec.round(2)

          [:tp, :fp, :tn, :fn].each do |metric|
            metrics_total_stage1[algo][metric] += (metrics[metric.to_s] || 0)
          end
        end

        if row['input_ids'] && JSON.parse(row['input_ids']).compact.count > 0
          # we predict targeting in the end
          precision_after_filter[algo].push prec_after.round(2)
          recall_after_filter[algo].push rec_after.round(2)

          predictions[algo] += 1

          [:tp, :fp, :tn, :fn].each do |metric|
            metrics_total_after_filter[algo][metric] += (metrics_after_filter[metric.to_s] || 0)
          end

          pvalue = row['pvalue']
          by_pvalue = row['corr_by_pvalue']
          holm_pvalue = row['corr_holm_pvalue']
          if pvalue && pvalue <= options[:pvalue_threshold]
            low_pvalue_predictions[algo] += 1
            low_pval_precision[algo][:pval].push prec_after.round(2)
            low_pval_recall[algo][:pval].push rec_after.round(2)

            [:tp, :fp, :tn, :fn].each do |metric|
              metrics_total_low_pval[algo][:pval][metric] += (metrics_after_filter[metric.to_s] || 0)
            end
          end
          if by_pvalue && by_pvalue <= options[:pvalue_threshold]
            low_by_pvalue_predictions[algo] += 1
            low_pval_precision[algo][:by].push prec_after.round(2)
            low_pval_recall[algo][:by].push rec_after.round(2)

            [:tp, :fp, :tn, :fn].each do |metric|
              metrics_total_low_pval[algo][:by][metric] += (metrics_after_filter[metric.to_s] || 0)
            end
          end
          if holm_pvalue && holm_pvalue <= options[:pvalue_threshold]
            low_holm_pvalue_predictions[algo] += 1
            low_pval_precision[algo][:holm].push prec_after.round(2)
            low_pval_recall[algo][:holm].push rec_after.round(2)

            [:tp, :fp, :tn, :fn].each do |metric|
              metrics_total_low_pval[algo][:holm][metric] += (metrics_after_filter[metric.to_s] || 0)
            end
          end
        end
      end
      break if page.last_page?
      page = page.next_page
      puts (_page = (_page + 1)).to_s.red
    end

    # format the data in a way useful for the graphs
    # total prec/rec at different stages
    File.open("stages_total_precision_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      # f.write "stage1"
      # algorithms.each do |algo|
        # tp = metrics_total_stage1[algo][:tp]
        # fp = metrics_total_stage1[algo][:fp]
        # prec = (tp + fp) == 0 ? 0 : tp / (tp + fp).to_f
        # f.write " #{prec.round(2)}"
      # end
      # f.puts
      f.write "all_hyps"
      algorithms.each do |algo|
        tp = metrics_total_after_filter[algo][:tp]
        fp = metrics_total_after_filter[algo][:fp]
        prec = (tp + fp) == 0 ? 0 : tp / (tp + fp).to_f
        f.write " #{prec.round(2)}"
      end
      f.puts
      f.write "low_pvals"
      algorithms.each do |algo|
        tp = metrics_total_low_pval[algo][:pval][:tp]
        fp = metrics_total_low_pval[algo][:pval][:fp]
        prec = (tp + fp) == 0 ? 0 : tp / (tp + fp).to_f
        f.write " #{prec.round(2)}"
      end
      f.puts
      f.write "low_pvals_w/BY"
      algorithms.each do |algo|
        tp = metrics_total_low_pval[algo][:by][:tp]
        fp = metrics_total_low_pval[algo][:by][:fp]
        prec = (tp + fp) == 0 ? 0 : tp / (tp + fp).to_f
        f.write " #{prec.round(2)}"
      end
      f.puts
      f.write "low_pvals_w/Holm"
      algorithms.each do |algo|
        tp = metrics_total_low_pval[algo][:holm][:tp]
        fp = metrics_total_low_pval[algo][:holm][:fp]
        prec = (tp + fp) == 0 ? 0 : tp / (tp + fp).to_f
        f.write " #{prec.round(2)}"
      end
      f.puts
    end
    File.open("stages_total_recall_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      # f.write "stage1"
      # algorithms.each do |algo|
        # tp = metrics_total_stage1[algo][:tp]
        # fn = metrics_total_stage1[algo][:fn]
        # prec = (tp + fn) == 0 ? 0 : tp / (tp + fn).to_f
        # f.write " #{prec.round(2)}"
      # end
      # f.puts
      f.write "all_hyps"
      algorithms.each do |algo|
        tp = metrics_total_after_filter[algo][:tp]
        fn = metrics_total_after_filter[algo][:fn]
        prec = (tp + fn) == 0 ? 0 : tp / (tp + fn).to_f
        f.write " #{prec.round(2)}"
      end
      f.puts
      f.write "low_pvals"
      algorithms.each do |algo|
        tp = metrics_total_low_pval[algo][:pval][:tp]
        fn = metrics_total_low_pval[algo][:pval][:fn]
        prec = (tp + fn) == 0 ? 0 : tp / (tp + fn).to_f
        f.write " #{prec.round(2)}"
      end
      f.puts
      f.write "low_pvals_w/BY"
      algorithms.each do |algo|
        tp = metrics_total_low_pval[algo][:by][:tp]
        fn = metrics_total_low_pval[algo][:by][:fn]
        prec = (tp + fn) == 0 ? 0 : tp / (tp + fn).to_f
        f.write " #{prec.round(2)}"
      end
      f.puts
      f.write "low_pvals_w/Holm"
      algorithms.each do |algo|
        tp = metrics_total_low_pval[algo][:holm][:tp]
        fn = metrics_total_low_pval[algo][:holm][:fn]
        prec = (tp + fn) == 0 ? 0 : tp / (tp + fn).to_f
        f.write " #{prec.round(2)}"
      end
      f.puts
    end
    # prec/rec after phase 1
    File.open("stage_1_precision_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      f.write "bottom_quartile"
      algorithms.each do |algo|
        n = (0.25 * precision[algo].count).round
        f.write " #{precision[algo].sort[n]}"
      end
      f.puts
      f.write "median"
      algorithms.each do |algo|
        n = (0.5 * precision[algo].count).round
        f.write " #{precision[algo].sort[n]}"
      end
      f.puts
      f.write "top_quartile"
      algorithms.each do |algo|
        n = (0.75 * precision[algo].count).round
        f.write " #{precision[algo].sort[n]}"
      end
      f.puts
    end
    File.open("stage_1_recall_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      f.write "bottom_quartile"
      algorithms.each do |algo|
        n = (0.25 * recall[algo].count).round
        f.write " #{recall[algo].sort[n]}"
      end
      f.puts
      f.write "median"
      algorithms.each do |algo|
        n = (0.5 * recall[algo].count).round
        f.write " #{recall[algo].sort[n]}"
      end
      f.puts
      f.write "top_quartile"
      algorithms.each do |algo|
        n = (0.75 * recall[algo].count).round
        f.write " #{recall[algo].sort[n]}"
      end
      f.puts
    end
    # prec/rec after filtering
    File.open("stage_1_precision_after_filter_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      f.write "bottom_quartile"
      algorithms.each do |algo|
        n = (0.25 * precision_after_filter[algo].count).round
        f.write " #{precision_after_filter[algo].sort[n]}"
      end
      f.puts
      f.write "median"
      algorithms.each do |algo|
        n = (0.5 * precision_after_filter[algo].count).round
        f.write " #{precision_after_filter[algo].sort[n]}"
      end
      f.puts
      f.write "top_quartile"
      algorithms.each do |algo|
        n = (0.75 * precision_after_filter[algo].count).round
        f.write " #{precision_after_filter[algo].sort[n]}"
      end
      f.puts
    end
    File.open("stage_1_recall_after_filter_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      f.write "bottom_quartile"
      algorithms.each do |algo|
        n = (0.25 * recall_after_filter[algo].count).round
        f.write " #{recall_after_filter[algo].sort[n]}"
      end
      f.puts
      f.write "median"
      algorithms.each do |algo|
        n = (0.5 * recall_after_filter[algo].count).round
        f.write " #{recall_after_filter[algo].sort[n]}"
      end
      f.puts
      f.write "top_quartile"
      algorithms.each do |algo|
        n = (0.75 * recall_after_filter[algo].count).round
        f.write " #{recall_after_filter[algo].sort[n]}"
      end
      f.puts
    end
    # prec/rec after filtering only on low pvalue guesses
    File.open("stage_1_precision_bottom_quart_low_pval_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      f.write "low_pvals"
      algorithms.each do |algo|
        n = (0.25 * low_pval_precision[algo][:pval].count).round
        f.write " #{low_pval_precision[algo][:pval].sort[n]}"
      end
      f.puts
      f.write "low_pvals_w/BY"
      algorithms.each do |algo|
        n = (0.25 * low_pval_precision[algo][:by].count).round
        f.write " #{low_pval_precision[algo][:by].sort[n]}"
      end
      f.puts
      f.write "Holm_correction"
      algorithms.each do |algo|
        n = (0.25 * low_pval_precision[algo][:holm].count).round
        f.write " #{low_pval_precision[algo][:holm].sort[n]}"
      end
      f.puts
    end
    File.open("stage_1_recall_bottom_quart_low_pval_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      f.write "low_pvals"
      algorithms.each do |algo|
        n = (0.25 * low_pval_recall[algo][:pval].count).round
        f.write " #{low_pval_recall[algo][:pval].sort[n]}"
      end
      f.puts
      f.write "low_pvals_w/BY"
      algorithms.each do |algo|
        n = (0.25 * low_pval_recall[algo][:by].count).round
        f.write " #{low_pval_recall[algo][:by].sort[n]}"
      end
      f.puts
      f.write "low_pvals_w/Holm"
      algorithms.each do |algo|
        n = (0.25 * low_pval_recall[algo][:holm].count).round
        f.write " #{low_pval_recall[algo][:holm].sort[n]}"
      end
      f.puts
    end
    File.open("stage_1_precision_median_low_pval_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      f.write "low_pvals"
      algorithms.each do |algo|
        n = (0.5 * low_pval_precision[algo][:pval].count).round
        f.write " #{low_pval_precision[algo][:pval].sort[n]}"
      end
      f.puts
      f.write "low_pvals_w/BY"
      algorithms.each do |algo|
        n = (0.5 * low_pval_precision[algo][:by].count).round
        f.write " #{low_pval_precision[algo][:by].sort[n]}"
      end
      f.puts
      f.write "low_pvals_w/Holm"
      algorithms.each do |algo|
        n = (0.5 * low_pval_precision[algo][:holm].count).round
        f.write " #{low_pval_precision[algo][:holm].sort[n]}"
      end
      f.puts
    end
    File.open("stage_1_recall_median_low_pval_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      f.write "low_pvals"
      algorithms.each do |algo|
        n = (0.5 * low_pval_recall[algo][:pval].count).round
        f.write " #{low_pval_recall[algo][:pval].sort[n]}"
      end
      f.puts
      f.write "low_pvals_w/BY"
      algorithms.each do |algo|
        n = (0.5 * low_pval_recall[algo][:by].count).round
        f.write " #{low_pval_recall[algo][:by].sort[n]}"
      end
      f.puts
      f.write "low_pvals_w/Holm"
      algorithms.each do |algo|
        n = (0.5 * low_pval_recall[algo][:holm].count).round
        f.write " #{low_pval_recall[algo][:holm].sort[n]}"
      end
      f.puts
    end
    # number of predictions and numbers with low pvalues
    File.open("stage_1_lowpvals_#{expt_id}.dat", 'w') do |f|
      f.puts "metrics #{algorithms.map { |a| @algo_translate[a] }.join(' ')}"
      f.write "stage_1_predictions_n"
      algorithms.each do |algo|
        f.write " #{stage_1_predictions[algo]}"
      end
      f.puts
      f.write "predictions_n"
      algorithms.each do |algo|
        f.write " #{predictions[algo]}"
      end
      f.puts
      f.write "low_pvalue_predictions"
      algorithms.each do |algo|
        f.write " #{low_pvalue_predictions[algo]}"
      end
      f.puts
      f.write "ratio"
      algorithms.each do |algo|
        if predictions[algo] > 0
          f.write " #{(low_pvalue_predictions[algo] / predictions[algo].to_f).round(2)}"
        else
          f.write " 0"
        end
      end
      f.puts
      f.write "low_by_pvalue_predictions"
      algorithms.each do |algo|
        f.write " #{low_by_pvalue_predictions[algo]}"
      end
      f.puts
      f.write "ratio"
      algorithms.each do |algo|
        if predictions[algo] > 0
          f.write " #{(low_by_pvalue_predictions[algo] / predictions[algo].to_f).round(2)}"
        else
          f.write " 0"
        end
      end
      f.puts
      f.write "low_holm_pvalue_predictions"
      algorithms.each do |algo|
        f.write " #{low_holm_pvalue_predictions[algo]}"
      end
      f.puts
      f.write "ratio"
      algorithms.each do |algo|
        if predictions[algo] > 0
          f.write " #{(low_holm_pvalue_predictions[algo] / predictions[algo].to_f).round(2)}"
        else
          f.write " 0"
        end
      end
      f.puts
    end
  end
end
