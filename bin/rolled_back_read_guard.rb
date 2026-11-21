# The guard prod_read.sh loads in its default and --read-only modes, before the rolled-back transaction. The rollback
# already keeps any database write on its connection from sticking; what a rollback can't take back is anything that
# leaves the database. So:
#
# - Outbound HTTP: refused at Net::HTTP (which ShopifyAPI, ActiveResource and HTTParty all ride on), except Rollbar,
#   and at Ethon/Typhoeus (libcurl, which Mechanic's HTTP and OAuth2 actions use). A read that reaches Shopify belongs
#   in --shopify-read (Locksmith) or --write: here a session refresh would be rolled back after Shopify had already
#   rotated the token.
# - Background jobs: enqueueing anything is refused, since a job lands in Redis whether or not the transaction rolls
#   back, and then runs on a worker with no guard. Fails closed: Sidekiq's client is required, not assumed.
# - Rails.cache: swapped for a private in-memory store, so a fetch during a dry run can't cache rows that never
#   committed for real requests to read.
#
# Left over, and accepted for reviewed scripts: writes on another connection (an advisory-lock checkout, a thread),
# small Redis counters, sequences in plain read mode (--read-only refuses nextval), and any deliberate bypass.
require "sidekiq/client"

module RolledBackReadGuard
  module HTTP
    def request(req, body = nil, &blk)
      raise "[read] refused #{req.method} #{address}#{req.path.to_s.split("?").first}: this mode doesn't leave the database" unless address.to_s == "api.rollbar.com"
      super
    end
  end

  module Curl
    def perform(*) = raise("[read] refused a libcurl request: this mode doesn't leave the database")
  end

  module NoJobs
    def push(*) = raise("[read] refused to enqueue a background job")
    def push_bulk(*) = raise("[read] refused to enqueue background jobs")
  end
end

::Net::HTTP.prepend(RolledBackReadGuard::HTTP)
::Ethon::Easy.prepend(RolledBackReadGuard::Curl) if defined?(::Ethon::Easy)
::Ethon::Multi.prepend(RolledBackReadGuard::Curl) if defined?(::Ethon::Multi)
::Sidekiq::Client.prepend(RolledBackReadGuard::NoJobs)
Rails.cache = ActiveSupport::Cache::MemoryStore.new
