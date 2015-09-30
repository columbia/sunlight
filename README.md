# Sunlight: increasing the web's transparency

Sunlight is a research project from Columbia University that aims to improve
transparency of data usage on the web. You can learn more on our
[website](https://columbia.github.io/sunlight/).

## The Sunlight code

We release the Sunlight code as a first building block for researchers and auditors
to use and build on. Please keep in mind that Sunlight is a reasearch prototype, and
the code is pretty messy.

## Install and use Sunlight

Here are some guidelines to install and use Sunlight. Some things are probably outdated,
don't hesitate to shoot us an email in case of problems.

### Install the necessary software on a linux machine

```
// packages you'll need (plus some useful stuff)
sudo apt-get install zsh
sudo apt-get install git
sudo apt-get install libqt4-dev
sudo apt-get install openssl
sudo apt-get install autoconf bison build-essential libssl-dev libyaml-dev libreadline6 libreadline6-dev zlib1g zlib1g-dev libffi-dev
sudo apt-get install nodejs

// install configs you like
// relog

// install redis
wget http://download.redis.io/redis-stable.tar.gz
tar xvzf redis-stable.tar.gz
cd redis-stable
make

// install rbenv (adapt if you use bash)
git clone https://github.com/sstephenson/rbenv.git ~/.rbenv
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.zshrc
echo 'eval "$(rbenv init -)"' >> ~/.zshrc
git clone https://github.com/sstephenson/ruby-build.git ~/.rbenv/plugins/ruby-build
source .zshrc
// install ruby
rbenv install 2.2.2
rbenv rehash
rbenv global 2.2.2
rbenv shell 2.2.2
rbenv rehash

//install Cassandra

// clone Sunlight
git clone git@github.com:columbia/sunlight.git
gem install bundle
rbenv rehash
// install gems
bundle install

```

### Run an experiment

You need to run your own data collection. You can tweak the
[XRay](http://xray.cs.columbia.edu/) code if
you want a starting point, or look at [OpenWPM](https://github.com/citp/OpenWPM).

To populate the data in cassandra, you should use the following calls:

```
Analytics::API.synchronize_schemas  # run once to create the tables in cassandra
Analytics::API.register_experiment(...)
Analytics::API.add_observation(...)
```

### Analyse data:

Install R on the computer
Install R package glmnet (terminal -> R -> install.packages("glmnet")
Then in rails use:

```
Analytics::API.analyse_all(...)  # or analyse for only 1 output
                                 # see Analytics::API.analyse for the options
Analytics::API.correct_pvalues(...)  # to apply the correction on all current
                                     # hypotheses
Analytics::API.get_hypothesis(...)  # to retrieve the results
```
