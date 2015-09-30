require 'bigdecimal'

# The purpose of this class is to contain methods for computing the confidence score of a particular targeting
# association produced by XRay.

class Analytics::Likelihood
  # @param [Integer] active_accounts_number   Number of accounts seeing an ad
  # @param [Integer] matching_accounts_number Number of active accounts that match the combination
  # @param [Integer] combination_size         Size of combination
  # @param [Numeric] alpha                    Probability of including an email
  # @param [Integer] email_number             Total number of emails used in the experiment
  # @return [Numeric] Prediction confidence. Specifically, the probability that the null hypothesis is true given our
  # observations
  def self.confidence_level(active_accounts_number, matching_accounts_number, combination_size, alpha)
    a = BigDecimal(alpha, 10)
    if combination_size > 1
      a = 1 - (1 - a) ** combination_size
    end
    right = matching_accounts_number
    wrong = active_accounts_number - matching_accounts_number
    R.eval <<EOF
r <- binom.test(c(#{right},#{wrong}), p=#{a}, alternative=c("greater"), conf.level=0.95)
pval <- r$p.value
EOF
    return R.pval
  end

  # @param [Integer] active_accounts_number   Number of accounts seeing an ad
  # @param [Integer] matching_accounts_number Number of active accounts that match the combination
  # @param [Integer] combination_size         Size of combination
  # @param [Numeric] alpha                    Probability of including an email
  # @param [Integer] email_number             Total number of emails used in the experiment
  # @return [Numeric] Prediction confidence. Specifically, the probability that the null hypothesis is true given our
  # observations
  def self._confidence_level(active_accounts_number, matching_accounts_number, combination_size, alpha, email_number)
    a = BigDecimal(alpha, 10)
    conf = monomial_exact(active_accounts_number, matching_accounts_number, a, email_number)
    if (combination_size > 1)
      c_bound = conjunction_bound(active_accounts_number, matching_accounts_number, combination_size, a, email_number)
      if (c_bound < conf) # conjunction_bound overestimates probability so we use the better of the two bounds
        conf = c_bound
      end
    end
    conf.to_f   # Convert to float for readability.
  end

  # Exact probability for conjunctions of size 1 (most common)
  # This is the probability of observing a single email in matching_a_n out of active_a_n accounts.
  def self.monomial_exact(active_accounts_number, matching_accounts_number, alpha, email_number)
    p = 0
    (matching_accounts_number..active_accounts_number).each do |i|
      p += self.binomial(active_accounts_number, i, alpha)
    end
    out = 0
    sign = -1
    pk = 1 #represents p to the power k
    (1..email_number).each do |k|
      sign *= -1
      pk *= p
      out += sign * self.choose(email_number, k) * pk
    end
    out
  end

  # Probability approximation for conjunctions of arbitrary size
  def self.conjunction_bound(active_accounts_number, matching_accounts_number, conj_size, alpha, email_number)
    self.choose(email_number, conj_size) * self.binomial(active_accounts_number, matching_accounts_number, alpha ** conj_size)
  end

  # Binomial Distribution
  def self.binomial(total, k, alpha)
    return self.choose(total,k) * (alpha**k) * ((1-alpha) ** (total - k))
  end

  # Binomial Function
  def self.choose(n, k)
    return (0...k).inject(1) do |m,i| (m * (n - i)) / (i + 1) end ## Uncomment this line to use non-memoized function
  end
end
