class Analytics::Mapping
  #######
  # api #
  #######
  def self.add(expt_id, profile_id, context_id, uncontrolled_vars, count)
    raise "wrong arguments in Analytics::Mapping.add" unless (
      expt_id.kind_of?(String) && profile_id.kind_of?(String) &&
      context_id.kind_of?(String) && uncontrolled_vars.kind_of?(Hash)
    )
    # we need sorted keys because it is part of the primary key
    uncontrolled_vars = Hash[uncontrolled_vars.sort]

    @prepared_insert ||= Cassandra::Instance.session.prepare(
      "UPDATE mappings SET count = count + ?  WHERE expt_id=?
       AND profile_id=? AND context_id=?  AND uncontrolled_vars=?;"
    )
    expt_id           = expt_id.force_encoding('UTF-8')
    profile_id        = profile_id.force_encoding('UTF-8')
    context_id        = context_id.force_encoding('UTF-8')
    uncontrolled_vars = uncontrolled_vars.to_json.force_encoding('UTF-8')
    Cassandra::Instance.execute(@prepared_insert,
                                { :arguments => [ count,
                                                  expt_id,
                                                  profile_id,
                                                  context_id,
                                                  uncontrolled_vars, ] })
  end

  def self.get_expt(expt_id)
    raise "wrong arguments in Analytics::Mapping.get_expt" unless expt_id.kind_of?(String)
    @prepared_get_expt ||= Cassandra::Instance.session.prepare(
      "SELECT * FROM mappings WHERE expt_id=?;"
    )
    expt_id = expt_id.force_encoding('UTF-8')
    page = Cassandra::Instance.session.execute(
      @prepared_get_expt,
      { :arguments => [ expt_id ],
        :page_size => 100_000, }
    )
    rows = []
    loop do
      rows += page.to_a
      break if page.last_page?
      page = page.next_page
    end
    rows
  end

  def self.delete_expt(expt_id)
    raise "wrong arguments in Analytics::Mappings.delete_expt" unless expt_id.kind_of?(String)
    expt_id = expt_id.force_encoding('UTF-8')
    Cassandra::Instance.session.execute("DELETE FROM mappings WHERE expt_id=?;",
                                        { :arguments => [ expt_id ] })
  end

  ##########
  # schema #
  ##########
  def self.synchronize_schema
    table_definition = <<-TABLE_CQL
      CREATE TABLE IF NOT EXISTS mappings (
       expt_id           VARCHAR,
       profile_id        VARCHAR,
       context_id        VARCHAR,
       uncontrolled_vars VARCHAR,
       count             COUNTER,
       PRIMARY KEY (expt_id, profile_id, context_id, uncontrolled_vars));
TABLE_CQL
    Cassandra::Instance.session.execute(table_definition)
  end
end
