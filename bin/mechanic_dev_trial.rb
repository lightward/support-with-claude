# Grant a Mechanic development store its super-extended trial (a hundred years, for stores that will never see
# customer traffic; mechanic-docs faq/do-you-have-a-plan-for-development-stores.md). Runs in mechanic-api production
# through prod_read.sh, with SHOP in the environment and Isaac's go (dry-run first, without --write):
#   prod_read.sh mechanic …/mechanic_dev_trial.rb [--write] SHOP=<name>.myshopify.com
# Prints the state before and after. Refuses a subscriber. Sets subscription_trial_ends_at the way the admin shop
# page does (with trial_days_granted cleared, so the shop counts as a manual trial). No email, no Shopify charge.
domain = ENV.fetch("SHOP")

shop = Shop.find_by!(shopify_domain: domain)
puts "email on file: #{shop.shopify_email.inspect}; Shopify plan: #{shop.shopify_plan_name.inspect}"
show = ->(label) {
  shop.reload
  puts "#{label}: subscription_trial_ends_at=#{shop.subscription_trial_ends_at&.iso8601} " \
       "days_left=#{shop.subscription_trial_days_left} trial_days_granted=#{shop.trial_days_granted.inspect} " \
       "subscriber=#{shop.subscriber} suspended_at=#{shop.suspended_at&.iso8601.inspect}"
}
show.("before")
if shop.subscriber
  puts "REFUSED: shop is a subscriber; nothing to extend"
else
  shop.update!(subscription_trial_ends_at: 100.years.from_now, trial_days_granted: nil)
  show.("after")
end
