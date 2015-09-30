Signal.trap 'SIGUSR2' do
  # Using a thread because we cannot acquire mutexes in a trap context in
  # ruby 2.0
  Thread.new do
    Thread.list.each do |thread|
      next if Thread.current == thread

      puts  '----[ Threads ]----' + '-' * (100-19)
      if thread.backtrace
        puts "Thread #{thread} #{thread['label']}"
        puts thread.backtrace.join("\n")
      else
        puts "Thread #{thread} #{thread['label']} -- no backtrace"
      end
    end
  end
end
