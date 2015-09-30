class Analytics::Utils
  def self.create_tables
    Analytics::ExperimentMeta.synchronize_schema
    Analytics::Observation.synchronize_schema
    Analytics::Mapping.synchronize_schema
    Analytics::Hypothesis.synchronize_schema
  end

  def self.delete_exp(expt_id)
    Analytics::ExperimentMeta.delete_exp(expt_id)
    Analytics::Observation.delete_exp(expt_id)
    Analytics::Mapping.delete_exp(expt_id)
    Analytics::Hypothesis.delete_exp(expt_id)
  end

  def self.hash_field(field)
    @map ||= {}
    h = Digest::MD5.hexdigest(field)
    @map[h] = field
    h
  end
  def self.reverse_hash(h)
    @map[h]
  end
  def self.get_cache
    @map
  end
  def self.flush_cache
    @map = {}
  end

  def self.reset_counters(expt_id)
    Analytics::Observation.get_expt(expt_id).each do |obs|
      Analytics::Observation.add(obs["expt_id"], obs["profile_id"], obs["context_id"],
                                 JSON.parse(obs["uncontrolled_vars"]), obs["output_id"],
                                 -obs["count"])
    end
    Analytics::Mapping.get_expt(expt_id).each do |obs|
      Analytics::Mapping.add(obs["expt_id"], obs["profile_id"], obs["context_id"],
                             JSON.parse(obs["uncontrolled_vars"]), -obs["count"])
    end
  end
end
