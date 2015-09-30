class Analytics::Sparse::LmFull
  def self.analyse(expt_id, output_id, options={})
    regression_options = {
      :familly => :linear,
      :model   => :full,
    }
    regression_options.reverse_merge! options

    Analytics::Sparse::Regression.regression(expt_id, output_id, regression_options)
  end

  def self.ordered_inputs(algorithm_results)
    Analytics::Sparse::Regression.ordered_inputs(algorithm_results)
  end

  def self.predict_output_presence(algorithm_results, inputs_in_profile)
    Analytics::Sparse::Regression.predict_output_presence(algorithm_results, inputs_in_profile)
  end

  def self.targeting_present?(algorithm_results)
    Analytics::Sparse::Regression.targeting_present?(algorithm_results)
  end
end
