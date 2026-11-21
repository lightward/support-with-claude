# The guard prod_read.sh loads in its default mode, before the rolled-back transaction. The rollback already keeps any
# database write from sticking; what a rollback can't take back is anything that leaves the database. So:
#
# - Outbound HTTP, at Net::HTTP (which ShopifyAPI, ActiveResource and HTTParty all ride on): refused, except Rollbar.
#   A read that reaches Shopify belongs in --shopify-read (Locksmith) or --write; here a session refresh would be
#   rolled back after Shopify had already rotated the token.
# - Background jobs: enqueueing anything is refused, since a job lands in Redis whether or not the transaction rolls
#   back, and then runs on a worker with no guard.
#
# Like bin/shopify_read_guard.rb, it catches accidents in scripts that have been read; it doesn't stop a deliberate
# bypass. Runs in both apps.
module RolledBackReadGuard
  module HTTP
    def request(req, body = nil, &blk)
      raise "[read] refused #{req.method} #{address}#{req.path.to_s.split("?").first}: this mode doesn't leave the database" unless address.to_s == "api.rollbar.com"
      super
    end
  end

  module NoJobs
    def push(*) = raise("[read] refused to enqueue a background job")
    def push_bulk(*) = raise("[read] refused to enqueue background jobs")
  end
end

::Net::HTTP.prepend(RolledBackReadGuard::HTTP)
::Sidekiq::Client.prepend(RolledBackReadGuard::NoJobs) if defined?(::Sidekiq::Client)
