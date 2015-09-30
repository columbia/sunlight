class Analytics::Tmp
  def self.context_percentage(expt_id, output_id, input_ids)
    out_ctxt = in_ctxt = 0
    obs = Analytics::Observation.get_expt_output(expt_id, output_id)
    profiles = []
    obs.each do |o|
      profiles.push(o["profile_id"])
      if input_ids.include?(o["context_id"])
        in_ctxt += o['count']
      else
        out_ctxt += o['count']
      end
    end
    tot = in_ctxt.to_f + out_ctxt.to_f
    return {} if tot == 0
    return {
      :in    => in_ctxt / tot,
      :out   => out_ctxt / tot,
      :tot   => tot,
      :acc_n => profiles.uniq.count
    }
  end

  # just convenience not to retype everything
  def self.analyse_all
  end
  def self.analyse
    Analytics::API.analyse('fexp11',
                           'aionline.edu',
                           :algorithms => [
                             :logit_simple,
                             :lm_simple,
                             :logit_full,
                             :lm_full,
                             :naive_bayes,
                             :set_intersection
                           ],
                           :only_expt_inputs => true,
                           :store_results => false,
                           :async => false,
                           :compute_pvalues => false,
                           :training_percent => 0.6,
                           :parameters => {
                             :naive_bayes => { :pin => 0.02,
                                               :pout => 0.0003,
                                               :prandom => 0.001 }
                           }
                          )
  end
end
