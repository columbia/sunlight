class Analytics::Filter::Accuracy
  def self.filter(expt_id, output_id, training_set, ordered_inputs, options={})
    default_options = {
      :data             => nil,       # potential precomputed data matrix
      :profile_ids      => :all,      # :all or an array of profile_ids, pass training_set
      :only_expt_inputs => false,     # use it to remove inputs not in the expt inputs,
                                      # like "Welcome to gmail" emails
      :max_combination_size => 5,     # max combination size
    }
    options.reverse_merge!(default_options)

    return [] unless ordered_inputs.count > 0

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

    sorted_candidates = ordered_inputs[0..options[:max_combination_size]]

    candidates_stats = {}
    sorted_candidates.count.times do |j|
      candidates_stats[j] = {
        :tp => 0,
        :fp => 0,
        :tn => 0,
        :fn => 0,
      }
    end

    training_set.each do |profile_id|
      profile_input_ids = mappings_full_hash[profile_id].keys.uniq
      sorted_candidates.count.times do |j|
        if (profile_input_ids & sorted_candidates[0..j]).count > 0
          # we would predict yes
          if observations_hash[profile_id] && observations_hash[profile_id] > 0
            # we do see it
            candidates_stats[j][:tp] += 1
          else
            candidates_stats[j][:fp] += 1
          end
        else
          # we would predict no
          if observations_hash[profile_id] && observations_hash[profile_id] > 0
            # we still see it
            candidates_stats[j][:fn] += 1
          else
            candidates_stats[j][:tn] += 1
          end
        end
      end
    end

    indices = candidates_stats.map do |k, v|
      tot = v[:tp] + v[:fp] + v[:tn] + v[:fn]
      acc = tot == 0 ? 0 : (v[:tp] + v[:tn]) / tot.to_f
      [k, acc]
    end
    # get the indice with max accuracy
    max_indice = indices.sort { |x, y| x.reverse <=> y.reverse }.reverse.first.first
    candidates = sorted_candidates[0..max_indice]

    return candidates
  end

  def self.predict_output_presence(ordered_inputs, inputs_in_profile)
    return (ordered_inputs & inputs_in_profile).count > 0
  end
end
