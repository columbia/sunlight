ENV['CASSADRA_URLS'] ||= "localhost"


require 'cassandra'
class Cassandra::Instance
  def self.cluster(reconnect=false)
    if @cluster == nil || reconnect
      @cluster = Cassandra.cluster(
        :hosts   => ENV['CASSADRA_URLS'].split(','),
        :timeout => 1 * 60,
        :retry_policy => Cassandra::Retry::Policies::Custom.new
      )
    end
    @cluster
  end

  def self.session(reconnect=false)
    if @session == nil || reconnect
      @session = self.cluster(reconnect).connect('sunlight')
    end
    @session
  end

  def self.execute(*args)
      self.session.execute(*args)
  end

  def self.create_keyspace(options={})
    default_options = { :alter => false }
    options.reverse_merge! default_options

    keyspace_definition = <<-KEYSPACE_CQL
      #{options[:alter] ? 'ALTER' : 'CREATE'} KEYSPACE sunlight
      WITH replication = {
        'class': 'NetworkTopologyStrategy',
        'AWS-us-west-2c': 2
      } AND DURABLE_WRITES = true;
KEYSPACE_CQL
    self.cluster.connect.execute(keyspace_definition)
  end
end

# a retry policy that retries 3 times for failed rads or writes
# retries once if cluster is unavailable
module Cassandra
  module Retry
    module Policies
      class Custom
        include Policy

        def read_timeout(statement, consistency, required, received, retrieved, retries)
          return reraise if retries > 2
          try_again(consistency)
        end

        def write_timeout(statement, consistency, type, required, received, retries)
          return reraise if retries > 2
          try_again(consistency)
        end

        def unavailable(statement, consistency, required, alive, retries)
          return reraise if retries > 0
          try_again(consistency)
        end
      end
    end
  end
end
