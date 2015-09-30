class Analytics::ExperimentMeta
  def self.register(expt_id, profile_ids, input_ids, uncontrolled_vars, profiles_percent_with_inputs)
    raise "wrong arguments in Analytics::ExperimentMeta.registier" unless (
      expt_id.kind_of?(String) && profile_ids.kind_of?(Array) && input_ids.kind_of?(Array) &&
      uncontrolled_vars.kind_of?(Array)
    )
    expt_id           = expt_id.force_encoding('UTF-8')
    profile_ids       = profile_ids.to_json.force_encoding('UTF-8')
    input_ids         = input_ids.to_json.force_encoding('UTF-8')
    uncontrolled_vars = uncontrolled_vars.to_json.force_encoding('UTF-8')
    Cassandra::Instance.session.execute(
      'INSERT INTO experiments (expt_id, profile_ids, input_ids, uncontrolled_vars, profiles_percent_with_inputs)
       VALUES (?, ?, ?, ?, ?)',
      { :arguments => [expt_id, profile_ids, input_ids, uncontrolled_vars, profiles_percent_with_inputs] }
    )
  end

  def self.get(expt_id)
    raise "wrong arguments in Analytics::ExperimentMeta.get" unless expt_id.kind_of?(String)
    @prepared_get_expt ||= Cassandra::Instance.session.prepare(
      "SELECT * FROM experiments WHERE expt_id=?;"
    )
    expt_id = expt_id.force_encoding('UTF-8')
    Cassandra::Instance.session.execute(@prepared_get_expt, { :arguments => [ expt_id ] })
  end

  def self.get_all_ids
    Cassandra::Instance.session.execute("SELECT DISTINCT expt_id FROM experiments;").map do |row|
      row['expt_id']
    end
  end

  def self.delete_expt(expt_id)
    raise "wrong arguments in Analytics::ExperimentMeta.delete_expt" unless (
      expt_id.kind_of?(String)
    )
    expt_id = expt_id.force_encoding('UTF-8')
    Cassandra::Instance.session.execute("DELETE FROM experiments WHERE expt_id=?;",
                                        { :arguments => [ expt_id ] })
  end

  ##########
  # schema #
  ##########
  def self.set(expt_id, key, value)
    Cassandra::Instance.session.execute(
      "UPDATE experiments SET #{key}=? WHERE expt_id=?;",
      { :arguments => [ value, expt_id ] }
    )
  end

  def self.synchronize_schema
    table_definition = <<-TABLE_CQL
      CREATE TABLE IF NOT EXISTS experiments (
       expt_id           VARCHAR,
       profile_ids       VARCHAR,
       input_ids         VARCHAR,
       uncontrolled_vars VARCHAR,
       profiles_percent_with_inputs DOUBLE,
       PRIMARY KEY (expt_id));
TABLE_CQL
    Cassandra::Instance.session.execute(table_definition)
  end
end
