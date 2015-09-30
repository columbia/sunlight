class Analytics::SparseRegression
  ##########
  # glmnet #
  ##########

  def self.regression_glmnet(expt_id, output_id, options={})
    default_options = {
      :sparse_familly       => :linear,  # :linear or :binomial
      :regular_familly      => :linear,  # :linear, :binomial, or :bayesglm
      :model                => :full,    # :full or :simple
      :profile_ids          => :all,       # :all or an array of profile_ids
      :data                 => nil,        # potential precomputed data matrix
      :only_expt_inputs     => false,      # use it to remove inputs not in the expt inputs,
      :max_combination_size => 5,          # max number of non null coefs for the sparse reg
      :coef_pvalue          => 0.01,       # max pvalue to keep a coef in the lm or glm
    }
    options.reverse_merge!(default_options)
    puts "#{options[:sparse_familly]} - #{options[:model]} - sparse".green

    data = options[:data] || Analytics::FormatData.matrix(expt_id, output_id,
                                         { :profile_ids      => options[:profile_ids],
                                           :model            => options[:model],
                                           :only_expt_inputs => options[:only_expt_inputs], })

    results = { :variables        => [],
                :variable_coefs   => [],
                :variable_stderr  => [],
                :variable_pvals   => [],
                :guesses          => [],
                :basic_guesses    => [],
                :filtered_guesses => [], }

    if    options[:sparse_familly] == :linear
      displays = data[:log_displays]
      puts "0 sum in linear sparse".red if displays.sum == 0
      return results if displays.sum == 0
    elsif options[:sparse_familly] == :binomial
      displays = data[:bool_displays]
      # glmnet doesn't do logit with only true values
      puts "0 sum in logit sparse".red if displays.sum == 0
      puts "all 1 in logit sparse".red if displays.sum == displays.count
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

    R.eval <<EOF
      library("glmnet")
      #{'library("arm")' if options[:regular_familly] == :bayesglm}
      setwd("#{Rails.root.to_s}")
      d <- read.csv("r_csv.csv")
      f <- as.formula(paste("~ 0 + ", paste(names(d)[#{options[:model] == :simple ? 3 : 4}:dim(d)[2]], collapse= " + ")))
      data <- model.matrix(f, data=d, sparse=TRUE)

      rm(fit)
      fit <- glmnet(data, d$displays, intercept=FALSE, alpha=1#{options[:sparse_familly] == :binomial ? ', family="binomial"' : ''})
      indices_with_right_df_n <- which(fit$df <= #{options[:max_combination_size]})
      lowest_lambda_with_right_df_n <- fit$lambda[tail(indices_with_right_df_n, n=1)]

      coefs <- coef(fit,s=lowest_lambda_with_right_df_n)
      non_null_indices <- which(matrix(coefs) != 0)
      var_names <- rownames(coefs)
      vars_with_non_null_coef <- sapply(non_null_indices, function(x) var_names[x])

      non_sparse_formula <- as.formula(paste("displays ~ ", paste(vars_with_non_null_coef, collapse=" + ")))
      r <- #{
        if options[:regular_familly] == :binomial
          "glm(formula = non_sparse_formula, family = binomial, data = d)"
        elsif options[:regular_familly] == :linear
          "lm(formula = non_sparse_formula, data = d)"
        elsif options[:regular_familly] == :bayesglm
          "bayesglm(formula = non_sparse_formula, family = binomial, data = d)"
        end
      }
      coefs  <- summary(r)$coef[,"Estimate"]
      stderr <- summary(r)$coef[,"Std. Error"]
      pvals  <- summary(r)$coef[,"Pr(>|#{options[:regular_familly] == :linear ? "t" : "z"}|)"]
      vars_names <- names(pvals)
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
      results[:variables]      = vars.map do |v|
        if v.downcase.include?('intercept')
          v
        else
          "#{v[0..1]}#{data[:h_to_inputs][v[2..-1]]}"
        end
      end
      results[:variable_coefs] = coefs
      results[:variable_stderr] = stderr
      results[:variable_pvals] = pvals
      guesses = self.analyse_results(vars,
                                     results[:variable_coefs],
                                     results[:variable_stderr])
      guesses = guesses.select { |v| !v.downcase.include?("intercept") }
                       .map { |v| v[2..-1] }
                       .compact.uniq
      results[:guesses]          = guesses.map { |e| data[:h_to_inputs][e] }
      results[:basic_guesses]    = results[:guesses]
      results[:filtered_guesses] = results[:guesses]
    rescue
      puts "ERROR sparse exp: #{expt_id} ad: #{output_id}"
    end
    return results
  end

  def self.analyse_results(variables, coefficients, standard_errors)
    # find coefficients that are bigger than 0 + 2 std_err and
    # that are bigger than the intercept coef
    intercept_coef = 0
    variables.each_with_index do |coef, i|
      intercept_coef = coefficients[i] if coef.downcase.include?("intercept")
    end
    coefficients.each_with_index
     .select { |coeff, i| coeff - 2 * standard_errors[i] > 0 && coeff >= intercept_coef }
     .map { |coeff, i| variables[i] }
  end
end
