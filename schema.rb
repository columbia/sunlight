# Account
  # has_many :email_snapshots
  # has_many :ad_snapshots

  # has_many :emails

  # def emails
    # email_snapshots.map(&:email)
  # end
# end

# Email # cluster
  # has_many :email_snapshots

# EmailSnapshot
  # belongs_to :account
  # belongs_to :emails
  # has_many :ad_snapshots

# AdSnapshot
  # belongs_to :account
  # belongs_to :email_snapshot
  # belongs_to :ad

# Ad # cluster
  # has_many :ad_snapshots


# AccountEmail
  # belongs_to :account
  # belongs_to :email

  # field :footprint # Hash[AccountAd => occurence]

# AccountAd
  # belongs_to :account
  # belongs_to :ad
