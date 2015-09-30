class Analytics::FormatData
  def self.hash_from_cassandra_rows(cassandra_rows, uncontrolled_vars_followed, options={})
    default_options = {
      :model       => :full,  # can be full or simple
      :profile_ids => :all,
      :hash_inputs => true,
    }
    options.reverse_merge!(default_options)

    h = {}
    cassandra_rows.each do |row|
      profile_id = row['profile_id']
      # we add only the profiles ids we care about
      next unless options[:profile_ids] == :all || options[:profile_ids].include?(profile_id)
      if options[:hash_inputs]
        context_id = Analytics::Utils.hash_field(row['context_id'])
      else
        context_id = row['context_id']
      end

      if options[:model] == :full
        h[profile_id] ||= {}
        if uncontrolled_vars_followed.count > 0
          h[profile_id][context_id] ||= {}
          h[profile_id][context_id][row["uncontrolled_vars"]] = row["count"]
        else
          h[profile_id][context_id] = row["count"]
        end
      elsif options[:model] == :simple
        if uncontrolled_vars_followed.count > 0
          h[profile_id] ||= Hash.new(0)
          h[profile_id][row["uncontrolled_vars"]] += row["count"]
        else
          h[profile_id] ||= 0
          h[profile_id] += row["count"]
        end
      end
    end
    return h
  end

  def self.matrix(expt_id, output_id, options={})
    default_options = {
      :profile_ids      => :all,
      :data             => nil,    # eventually pre-fetched data from cassandra
      :model            => :full,  # can be full or simple
      :only_expt_inputs => false,  # use it to remove inputs not in the expt inputs,
                                   # like "Welcome to gmail" emails
    }
    options.reverse_merge!(default_options)

    data         = options[:data] || Analytics::API.ouput_data(expt_id, output_id)
    expt_meta    = data[:expt_meta]
    mappings     = data[:mappings]
    observations = data[:observations]

    Analytics::Utils.flush_cache
    uncontrolled_vars = expt_meta['uncontrolled_vars'].sort
    mappings_hash     = Analytics::FormatData.hash_from_cassandra_rows(
      mappings,
      uncontrolled_vars,
      :model => options[:model],
      :profile_ids => options[:profile_ids]
    )
    if options[:model] == :full
      mappings_full_hash = mappings_hash
    elsif options[:model] == :simple
      mappings_full_hash = Analytics::FormatData.hash_from_cassandra_rows(
        mappings,
        uncontrolled_vars,
        :model => :full,
        :profile_ids => options[:profile_ids]
      )
    end
    observations_hash = Analytics::FormatData.hash_from_cassandra_rows(
      observations,
      uncontrolled_vars,
      :model => options[:model],
      :profile_ids => options[:profile_ids]
    )
    cache = Analytics::Utils.get_cache
    Analytics::Utils.flush_cache

    input_ids     = mappings_full_hash.map { |_, v| v.keys }.flatten.uniq.sort
    log_displays  = []
    bool_displays = []
    matrix        = []
    # remove non expt_inputs if necessary
    if options[:only_expt_inputs]
      input_ids = input_ids.select do |input_id|
        expt_meta['input_ids'].include?(cache[input_id])
      end
    end

    if    options[:model] == :full
      variables     = ["profile", "context", *uncontrolled_vars]
      input_ids.each { |input_id| variables += ["CE#{input_id}", "PE#{input_id}"] }
    elsif options[:model] == :simple
      variables     = ["profile", *uncontrolled_vars]
      input_ids.each { |input_id| variables += ["AE#{input_id}"] }
    end
    all_expt_displays = mappings.reduce(0) { |acc, mapp| acc + mapp['count'] }.to_f
    mappings_hash.each do |profile_id, context_data|
      if options[:model] == :full
        profile_input_ids = context_data.keys.uniq
        context_data.each do |context_id, measured_data|
          if uncontrolled_vars.count > 0
            measured_data = measured_data.map do |uvars, count|
              input_count = (observations_hash[profile_id][context_id][uvars] rescue nil)
              input_count ||= 0
              uvars       = uvars == "" ? {} : JSON.parse(uvars)
              [uvars.values, count, input_count]
            end
          else
            input_count   = (observations_hash[profile_id][context_id] rescue nil)
            input_count   ||= 0
            measured_data = [[[], measured_data, input_count]]
          end
          measured_data.each do |(uvars, expt_count, count)|
            profile = profile_input_ids.include?(context_id) ? 1 : 0
            line    = [profile_id, context_id, *uvars]
            input_ids.each do |input_id|
              context = input_id == context_id ? 1 : 0
              line   += [context, profile]
            end
            matrix.push line
            log_displays.push(Math.log(1 + (count * all_expt_displays) / expt_count.to_f))
            bool_displays.push(count > 0 ? 1 : 0)
          end
        end
      elsif options[:model] == :simple
        profile_input_ids = mappings_full_hash[profile_id].keys.uniq
        measured_data = context_data
        if uncontrolled_vars.count > 0
          measured_data = measured_data.map do |uvars, count|
            input_count = (observations_hash[profile_id][uvars] rescue nil)
            input_count ||= 0
            uvars       = uvars == "" ? {} : JSON.parse(uvars)
            [uvars.values, count, input_count]
          end
        else
          input_count   = (observations_hash[profile_id] rescue nil)
          input_count   ||= 0
          measured_data = [[[], measured_data, input_count]]
        end
        measured_data.each do |(uvars, expt_count, count)|
          line    = [profile_id, *uvars]
          input_ids.each do |input_id|
            profile = profile_input_ids.include?(input_id) ? 1 : 0
            line    += [profile]
          end
          matrix.push line
          log_displays.push(Math.log(1 + (count * all_expt_displays) / expt_count.to_f))
          bool_displays.push(count > 0 ? 1 : 0)
        end
      end
    end
    { :variables     => variables,
      :h_to_inputs   => cache,
      :log_displays  => log_displays,
      :bool_displays => bool_displays,
      :matrix        => matrix, }
  end
end
