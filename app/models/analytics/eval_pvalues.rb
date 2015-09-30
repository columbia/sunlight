class Analytics::EvalPvalues
  def self.pvalues_cdf(expt_id, algorithms, key, pval)
    hyp = Analytics::Hypothesis.get_expt(expt_id).select do |h|
      h['input_ids'] != "[]" && algorithms.include?(h['algorithm_type'].to_sym)
    end.group_by { |h| h['algorithm_type'] }
    pvalues = hyp.map do |algo, data|
      [
       algo.to_sym,
       data.map { |h| JSON.parse(h['algorithm_data'], :symbolize_names => true) }
           .select { |h| h[key].count > 0 }
           .map { |h| h[pval] }
           .sort
      ]
    end
    corrected_pvalues = pvalues.map do |algo, pvals|
      [
        algo,
        Analytics::Evaluation.correct_pvalues(pvals).sort
      ]
    end
    pvalues = Hash[pvalues]
    corrected_pvalues = Hash[corrected_pvalues]

    range = 9.times.map { |n| n+1 }
    points = 8.times.map { |i| range.map { |n| n / (10.0 ** i) } }.flatten.sort

    data_pvals = "graphs/pvalues_cdf_#{key}.dat"
    data_corr_pvals = "graphs/corrected_pvalues_cdf_#{key}.dat"
    data_pvals_percent = "graphs/pvalues_percent_cdf_#{key}.dat"
    data_corr_pvals_percent = "graphs/corrected_pvalues_percent_cdf_#{key}.dat"
    f_pvals = File.open(data_pvals, 'w')
    f_corr_pvals = File.open(data_corr_pvals, 'w')
    f_pvals_percent = File.open(data_pvals_percent, 'w')
    f_corr_pvals_percent = File.open(data_corr_pvals_percent, 'w')
    f_pvals.puts "pvalue #{algorithms.join(' ')}"
    f_corr_pvals.puts "pvalue #{algorithms.join(' ')}"
    f_pvals_percent.puts "pvalue #{algorithms.join(' ')}"
    f_corr_pvals_percent.puts "pvalue #{algorithms.join(' ')}"
    points.each do |point|
      pval_points = algorithms.map do |algo|
        pvalues[algo].select { |pv| pv <= point }.count
      end
      corr_pval_points = algorithms.map do |algo|
        corrected_pvalues[algo].select { |pv| pv <= point }.count
      end
      pval_points_percent = algorithms.map do |algo|
        pvalues[algo].select { |pv| pv <= point }.count / pvalues[algo].count.to_f
      end
      corr_pval_points_percent = algorithms.map do |algo|
        corrected_pvalues[algo].select { |pv| pv <= point }.count / corrected_pvalues[algo].count.to_f
      end
      f_pvals.puts "#{point} #{pval_points.join(' ')}"
      f_corr_pvals.puts "#{point} #{corr_pval_points.join(' ')}"
      f_pvals_percent.puts "#{point} #{pval_points_percent.join(' ')}"
      f_corr_pvals_percent.puts "#{point} #{corr_pval_points_percent.join(' ')}"
    end
    f_pvals.close
    f_corr_pvals.close
    f_pvals_percent.close
    f_corr_pvals_percent.close
  end
end
