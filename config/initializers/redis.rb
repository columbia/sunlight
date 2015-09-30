ENV['REDIS_URL'] ||= "localhost"

class Redis
  def self.instance
    @redis ||= Redis.new(:driver => :hiredis, :timeout => 1*60)
  end
end
