class Analytics::Filter::Pvalue
  def self.filter(expt_id, output_id, training_set, ordered_inputs, options={})
    default_options = {
      :data             => nil,   # potential precomputed data matrix
      :profile_ids      => :all,  # :all or an array of profile_ids, pass training_set
      :only_expt_inputs => false, # use it to remove inputs not in the expt inputs,
                                  # like "Welcome to gmail" emails
      :pvalue_threshold => 0.05,  # the max pvalue on profile ids. If it is above that
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
      :profile_ids => training_set,
      :hash_inputs => false,
    )
    # observations_hash simple and no uncontroller_vars
    # is a hash of { profile_id => #displays }
    observations_hash = Analytics::FormatData.hash_from_cassandra_rows(
      observations,
      [],
      :model => :simple,
      :profile_ids => training_set,
      :hash_inputs => false,
    )
    Analytics::Utils.flush_cache

    # now we compute the pvalue of the training set
    profiles_with_output_n = training_set.select do |profile_id|
      observations_hash[profile_id] && observations_hash[profile_id] > 0
    end.count

    profiles_with_output_and_input_n = training_set.select do |profile_id|
      observations_hash[profile_id]       &&
        observations_hash[profile_id] > 0 &&
      mappings_full_hash[profile_id]      &&
      (mappings_full_hash[profile_id].keys & ordered_inputs).count > 0
   end.count

   if options[:only_expt_inputs]
     input_n = data[:expt_meta]["input_ids"].uniq.count
   else
     input_n = mappings_full_hash.map { |profile, d| d.keys }
                                 .flatten.uniq.count
   end
   pvalue = Analytics::Likelihood.confidence_level(
     profiles_with_output_n,
     profiles_with_output_and_input_n,
     ordered_inputs.count,
     data[:expt_meta]['profiles_percent_with_inputs'])

    return [] if pvalue > options[:pvalue_threshold]
    return ordered_inputs
  end

  def self.predict_output_presence(ordered_inputs, inputs_in_profile)
    return (ordered_inputs & inputs_in_profile).count > 0
  end
end
