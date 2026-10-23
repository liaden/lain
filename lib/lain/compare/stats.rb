# frozen_string_literal: true

module Lain
  class Compare
    # Interval statistics for the bench reports, in plain Ruby: a second
    # toolchain for a few lines of arithmetic is not worth its install.
    #
    # The t quantile is exact up to {NORMAL_FROM} samples and the normal
    # quantile beyond it, where the two differ by under 4%.
    module Stats
      Interval = Data.define(:low, :high)

      NORMAL_FROM = 30
      private_constant :NORMAL_FROM

      # @return [Interval, nil] nil when fewer than 2 values leave no spread to measure
      def self.mean_interval(values, confidence: 0.95)
        n = values.size
        return nil if n < 2

        mean = values.sum(0.0) / n
        sd = Math.sqrt(values.sum(0.0) { |value| (value - mean)**2 } / (n - 1))
        margin = quantile(confidence, n - 1) * sd / Math.sqrt(n)
        Interval.new(low: mean - margin, high: mean + margin)
      end

      def self.wilson(successes, trials, confidence: 0.95)
        raise ArgumentError, "wilson needs at least 1 trial" unless trials.positive?

        z = normal_quantile(1 - ((1 - confidence) / 2))
        phat = successes.fdiv(trials)
        scale = 1 + ((z**2) / trials)
        centre = (phat + ((z**2) / (2 * trials))) / scale
        margin = z * wilson_spread(phat, trials, z) / scale
        wilson_bounds(successes, trials, centre, margin)
      end

      # Rounding leaves 2.8e-17 where the exact bound is 0 (all failures) or 1 (all successes).
      def self.wilson_bounds(successes, trials, centre, margin)
        Interval.new(low: successes.zero? ? 0.0 : (centre - margin).clamp(0.0, 1.0),
                     high: successes == trials ? 1.0 : (centre + margin).clamp(0.0, 1.0))
      end
      private_class_method :wilson_bounds

      def self.wilson_spread(phat, trials, zscore)
        Math.sqrt((phat * (1 - phat) / trials) + ((zscore**2) / (4 * (trials**2))))
      end
      private_class_method :wilson_spread

      # The largest rate still consistent with `failures` in `trials` at the
      # given confidence: bisected, because no closed form exists past 0 failures.
      def self.clopper_pearson_upper(failures, trials, confidence: 0.95)
        return 1.0 if failures >= trials

        bisect(0.0, 1.0) { |rate| binomial_cdf(failures, trials, rate) > 1 - confidence }
      end

      def self.brier(forecasts, outcomes)
        if forecasts.empty? || forecasts.size != outcomes.size
          raise ArgumentError,
                "brier needs equal, non-empty forecasts and outcomes"
        end

        forecasts.zip(outcomes).sum(0.0) { |forecast, outcome| (forecast - outcome)**2 } / forecasts.size
      end

      def self.quantile(confidence, degrees)
        upper = 1 - ((1 - confidence) / 2)
        return normal_quantile(upper) if degrees > NORMAL_FROM

        bisect(0.0, 1000.0) { |x| t_cdf(x, degrees) < upper }
      end
      private_class_method :quantile

      def self.normal_quantile(probability)
        bisect(0.0, 10.0) { |x| (1 + Math.erf(x / Math.sqrt(2))) / 2 < probability }
      end
      private_class_method :normal_quantile

      # 200 halvings outlast Float precision, so the loop always converges.
      def self.bisect(low, high, &below)
        200.times do
          mid = (low + high) / 2
          yield(mid) ? low = mid : high = mid
        end
        (low + high) / 2
      end
      private_class_method :bisect

      def self.binomial_cdf(failures, trials, rate)
        (0..failures).sum(0.0) do |k|
          Math.exp(log_choose(trials, k) + (k * Math.log(rate)) + ((trials - k) * Math.log1p(-rate)))
        end
      end
      private_class_method :binomial_cdf

      def self.log_choose(total, chosen) = log_gamma(total + 1) - log_gamma(chosen + 1) - log_gamma(total - chosen + 1)
      private_class_method :log_choose

      def self.log_gamma(count) = Math.lgamma(count).first
      private_class_method :log_gamma

      def self.t_cdf(point, degrees)
        tail = 0.5 * incomplete_beta(degrees / 2.0, 0.5, degrees / (degrees + (point**2)))
        point.positive? ? 1 - tail : tail
      end
      private_class_method :t_cdf

      # Regularized incomplete beta; the fraction converges fast only below the mean, so flip above it.
      def self.incomplete_beta(alpha, beta, point)
        return point if point.zero? || point == 1

        front = beta_front(alpha, beta, point)
        if point < (alpha + 1) / (alpha + beta + 2)
          front * beta_fraction(alpha, beta, point) / alpha
        else
          1 - (front * beta_fraction(beta, alpha, 1 - point) / beta)
        end
      end
      private_class_method :incomplete_beta

      def self.beta_front(alpha, beta, point)
        Math.exp(log_gamma(alpha + beta) - log_gamma(alpha) - log_gamma(beta) +
                 (alpha * Math.log(point)) + (beta * Math.log1p(-point)))
      end
      private_class_method :beta_front

      # Lentz's continued fraction for the incomplete beta.
      def self.beta_fraction(alpha, beta, point)
        c_term = 1.0
        d_term = 1 / nonzero(1 - ((alpha + beta) * point / (alpha + 1)))
        result = d_term
        (1..300).each do |step|
          beta_terms(alpha, beta, point, step).each do |term|
            d_term = 1 / nonzero(1 + (term * d_term))
            c_term = nonzero(1 + (term / c_term))
            result *= d_term * c_term
          end
        end
        result
      end
      private_class_method :beta_fraction

      def self.beta_terms(alpha, beta, point, step)
        even = alpha + (2 * step)
        [step * (beta - step) * point / ((even - 1) * even),
         -(alpha + step) * (alpha + beta + step) * point / (even * (even + 1))]
      end
      private_class_method :beta_terms

      # Keeps a vanishing denominator from dividing by zero.
      def self.nonzero(value) = value.abs < 1e-300 ? 1e-300 : value
      private_class_method :nonzero
    end
  end
end
