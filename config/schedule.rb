set :output, "/var/log/cron_whenever.log"

set :job_template, "/usr/bin/zsh -l -c ':job'"

# to play nice with rbenv, source the zshrc
# /!\ this assumes you use zsh
job_type :runner_zsh_sourced, "source ~/.zshrc; cd :path && bin/rails runner -e :environment ':task' :output"

every 1.day, :at => '3:30 am' do
  runner_zsh_sourced "Collect.perform"
end

every 1.day, :at => '1:30 am' do
  runner_zsh_sourced "Analyse.perform"
end

every 1.hour do
  runner_zsh_sourced "SendEmails.perform"
end
