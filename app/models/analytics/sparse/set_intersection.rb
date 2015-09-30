class Analytics::Sparse::SetIntersection
  def self.analyse(expt_id, output_id, options={})
    default_options = {
      :profile_ids      => :all,     # :all or an array of profile_ids
      :data             => nil,      # potential precomputed data matrix
      :only_expt_inputs => false,    # use it to remove inputs not in the expt inputs,
                                     # like "Welcome to gmail" emails
      :parameters       => { :max_combination_size => 5, :threshold => 0.99 },
      :max_combination_size => 5,    # max combination size
    }
    options.reverse_merge!(default_options)

    data         = options[:data] || Analytics::API.ouput_data(expt_id, output_id)
    expt_meta    = data[:expt_meta]
    mappings     = data[:mappings]
    observations = data[:observations]

    Analytics::Utils.flush_cache
    # mappings_hash full and no uncontroller_vars
    # is a hash of { profile_id => input_id => #displays }
    mappings_full_hash = Analytics::FormatData.hash_from_cassandra_rows(
      mappings,
      [],
      :model => :full,
      :profile_ids => options[:profile_ids]
    )
    # observations_hash simple and no uncontroller_vars
    # is a hash of { profile_id => #displays }
    observations_hash = Analytics::FormatData.hash_from_cassandra_rows(
      observations,
      [],
      :model => :simple,
      :profile_ids => options[:profile_ids]
    )
    cache = Analytics::Utils.get_cache
    Analytics::Utils.flush_cache

    input_ids = mappings_full_hash.map { |_, v| v.keys }.flatten.uniq.sort
    # remove non expt_inputs if necessary
    if options[:only_expt_inputs]
      input_ids = input_ids.select do |input_id|
        expt_meta['input_ids'].include?(cache[input_id])
      end
    end
    profile_ids = mappings_full_hash.keys.uniq
    profiles_w_output = profile_ids.select do |profile_id|
      observations_hash[profile_id] && observations_hash[profile_id] > 0
    end
    profile_input_map = {}
    profile_ids.each do |profile_id|
      profile_input_map[profile_id] = (mappings_full_hash[profile_id].keys.uniq & input_ids)
    end

    x        = options[:parameters][:threshold]
    max_size = options[:parameters][:max_combination_size]

    profiles_w_output_count = profiles_w_output.count.to_f

    covered_profiles_w_output = 0
    targeted_inputs = []
    while covered_profiles_w_output / profiles_w_output_count < x &&
          targeted_inputs.count < max_size
      # input_id => list of covered active profiles
      covered_active_profiles = {}
      profiles_w_output.each do |profile_id|
        next if profile_input_map[profile_id] == nil
        profile_input_map[profile_id].each do |input_id|
          covered_active_profiles[input_id] ||= []
          covered_active_profiles[input_id].push profile_id
        end
      end
      break if covered_active_profiles.count == 0
      input_id, profiles = covered_active_profiles.sort_by { |k,v| v.count }.last
      targeted_inputs.push input_id
      profiles_w_output = profiles_w_output - profiles
      covered_profiles_w_output += profiles.count
    end

    # ordered candidates for filtering function
    profiles_w_output = profile_ids.select do |profile_id|
      observations_hash[profile_id] && observations_hash[profile_id] > 0
    end
    sorted_candidates = []
    options[:max_combination_size].times do
      break if profiles_w_output.count == 0
      covered_active_profiles = {}
      profiles_w_output.each do |profile_id|
        next if profile_input_map[profile_id] == nil
        profile_input_map[profile_id].each do |input|
          covered_active_profiles[input] ||= []
          covered_active_profiles[input].push profile_id
        end
      end
      break if covered_active_profiles.count == 0
      input_id, profiles = covered_active_profiles.sort_by { |k,v| v.count }.last
      sorted_candidates.append input_id
      profiles_w_output = profiles_w_output - profiles
    end

    targeted = covered_profiles_w_output.to_f / profiles_w_output_count >= x &&
               targeted_inputs.count <= max_size

    targeted_inputs.map! { |id| cache[id] }
    sorted_candidates.map! { |id| cache[id] }

    result = { :targeting_present     => targeted,
               :proportion_covered    => covered_profiles_w_output / profiles_w_output_count,
               :combination_size      => targeted_inputs.count,
               :active_accounts_tot_n => profiles_w_output_count.to_i,
               :inputs_considered     => targeted_inputs,
               :guesses               => (targeted ? targeted_inputs : []),
               :ordered_inputs        => sorted_candidates, }
    return result
  end

  def self.ordered_inputs(algorithm_results)
    algorithm_results[:ordered_inputs]
  end

  def self.predict_output_presence(algorithm_results, inputs_in_profile)
    algorithm_results[:targeting_present] &&
    (algorithm_results[:guesses] & inputs_in_profile).count > 0
  end

  def self.targeting_present?(algorithm_results)
    !!algorithm_results[:targeting_present]
  end
end
