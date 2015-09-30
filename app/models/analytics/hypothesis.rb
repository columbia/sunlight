class Analytics::Hypothesis
  #######
  # api #
  #######
  def self.add(expt_id, output_id, algorithm,
               input_ids, confidences, pvalue,
               algorithm_data)
    algorithm = algorithm.to_s
    if !input_ids.kind_of?(String)
      input_ids = input_ids.to_json
    end
    if !confidences.kind_of?(String)
      confidences = confidences.to_json
    end
    if !algorithm_data.kind_of?(String)
      algorithm_data = algorithm_data.to_json
    end

    @prepared_insert ||= Cassandra::Instance.session.prepare(
      'INSERT INTO hypothesis (expt_id, output_id, algorithm_type, input_ids,
       confidences, pvalue, algorithm_data) VALUES (?, ?, ?, ?, ?, ?, ?);',
    )
    expt_id        = expt_id.force_encoding('UTF-8')
    output_id      = output_id.force_encoding('UTF-8')
    algorithm      = algorithm.force_encoding('UTF-8')
    input_ids      = input_ids.force_encoding('UTF-8')
    confidences    = confidences.force_encoding('UTF-8')
    pvalue         = pvalue
    algorithm_data = algorithm_data.force_encoding('UTF-8')
    Cassandra::Instance.execute(@prepared_insert,
                                { :arguments => [ expt_id,
                                                  output_id,
                                                  algorithm,
                                                  input_ids,
                                                  confidences,
                                                  pvalue,
                                                  algorithm_data, ] })
  end

  # id is an array of all values that form PRIMARY KEY in order
  # key is the key to set in the column (has to be in the schema
  # value value to set for that key
  # TODO add async options for better perfs
  def self.set_corrected_pvalues(id, corr_by_pvalue, corr_holm_pvalue, options={})
    default_options = { :async => false }
    options.reverse_merge!(default_options)

    @prepared_pval_set ||= Cassandra::Instance.session.prepare(
      'INSERT INTO hypothesis (expt_id, output_id, algorithm_type,
       corr_by_pvalue, corr_holm_pvalue)
       VALUES (?, ?, ?, ?, ?);',
    )
    expt_id   = id[0].to_s.force_encoding('UTF-8')
    output_id = id[1].to_s.force_encoding('UTF-8')
    algorithm = id[2].to_s.force_encoding('UTF-8')
    args = { :arguments => [ expt_id,
                             output_id,
                             algorithm,
                             corr_by_pvalue,
                             corr_holm_pvalue, ] }
    if options[:async]
      Cassandra::Instance.execute_async(@prepared_pval_set, args)
    else
      Cassandra::Instance.execute(@prepared_pval_set, args)
    end
  end

  def self.get_expt(expt_id)
    raise "wrong arguments in Analytics::Hypothesis.get_expt_hypothesis" unless expt_id.kind_of?(String)
    @prepared_get_expt ||= Cassandra::Instance.session.prepare(
      "SELECT * FROM hypothesis WHERE expt_id=?;"
    )
    expt_id = expt_id.force_encoding('UTF-8')
    page = Cassandra::Instance.session.execute(
      @prepared_get_expt,
      { :arguments => [ expt_id ],
        :page_size => 1_000 }
    )
    rows = []
    loop do
      rows += page.to_a
      break if page.last_page?
      page = page.next_page
    end
    rows
  end

  def self.get_algorithm(expt_id, algorithm)
    raise "wrong arguments in Analytics::Hypothesis.get_expt_hypothesis" unless expt_id.kind_of?(String)
    @prepared_get_expt ||= Cassandra::Instance.session.prepare(
      "SELECT * FROM hypothesis WHERE expt_id=?;"
    )
    expt_id = expt_id.force_encoding('UTF-8')
    # algorithm = algorithm.to_s.force_encoding('UTF-8')
    page = Cassandra::Instance.session.execute(
      @prepared_get_expt,
      { :arguments => [ expt_id, ],
        :page_size => 1_000 }
    )
    rows = []
    loop do
      rows += page.to_a.select { |h| h['algorithm_type'].to_s == algorithm.to_s }
      break if page.last_page?
      page = page.next_page
    end
    rows
  end

  def self.get_output(expt_id, output_id)
    raise "wrong arguments in Analytics::Hypothesis.get_output_hypothesis" unless (
      expt_id.kind_of?(String) && output_id.kind_of?(String)
    )
    @prepared_get_output ||= Cassandra::Instance.session.prepare(
      "SELECT * FROM hypothesis WHERE expt_id=? AND output_id=?;"
    )
    expt_id   = expt_id.force_encoding('UTF-8')
    output_id = output_id.force_encoding('UTF-8')
    page = Cassandra::Instance.session.execute(
      @prepared_get_output,
      { :arguments => [ expt_id, output_id ],
        :page_size => 1_000, }
    )
    rows = []
    loop do
      rows += page.to_a
      break if page.last_page?
      page = page.next_page
    end
    rows
  end

  def self.get_all_outputs(expt_id)
    raise "wrong arguments in Analytics::Observation.get_expt" unless expt_id.kind_of?(String)
    @prepared_get_expt_outputs ||= Cassandra::Instance.session.prepare(
      "SELECT output_id FROM hypothesis WHERE expt_id=?;"
    )
    expt_id = expt_id.force_encoding('UTF-8')
    page = Cassandra::Instance.session.execute(
      @prepared_get_expt_outputs,
      { :arguments => [ expt_id ] }
    )
    rows = []
    loop do
      rows += page.to_a
      break if page.last_page?
      page = page.next_page
    end
    rows.map { |d| d['output_id'] }.uniq
  end

  def self.delete_expt(expt_id)
    raise "wrong arguments in Analytics::Hypthesis.delete_expt" unless expt_id.kind_of?(String)
    expt_id = expt_id.force_encoding('UTF-8')
    Cassandra::Instance.session.execute("DELETE FROM hypothesis WHERE expt_id=?;",
                                        { :arguments => [ expt_id ] })
  end

  ##########
  # schema #
  ##########
  def self.synchronize_schema
    table_definition = <<-TABLE_CQL
      CREATE TABLE IF NOT EXISTS hypothesis (
       expt_id           VARCHAR,
       output_id         VARCHAR,
       algorithm_type    VARCHAR,
       input_ids         VARCHAR,
       confidences       VARCHAR,
       pvalue            DOUBLE,
       corr_by_pvalue    DOUBLE,
       corr_holm_pvalue  DOUBLE,
       algorithm_data    VARCHAR,
       PRIMARY KEY (expt_id, output_id, algorithm_type));
TABLE_CQL
    Cassandra::Instance.session.execute(table_definition)
  end
end
