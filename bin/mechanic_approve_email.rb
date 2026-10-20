# Approve a Mechanic shop for sending email. Runs in mechanic-api production through prod_read.sh --write, with Isaac's
# go on every run (no standing go, on purpose: approval commits Lightward to sending someone else's mail, without limit,
# so a Lightward human is part of each one):
#   prod_read.sh mechanic ~/.claude/skills/support/bin/mechanic_approve_email.rb --write SHOP=<name>.myshopify.com
# Prints the state before and after; writes nothing if the shop is already approved.
domain = ENV.fetch("SHOP")
shop = Shop.find_by!(shopify_domain: domain)
show = ->(label) {
  shop.reload
  puts "#{label}: approved_for_email=#{shop.approved_for_email} custom_sender=#{shop.custom_email_from_address.inspect} " \
       "sends_from=#{(shop.email_from_address rescue "?")} plan=#{shop.try(:shopify_plan_name)} created=#{shop.created_at.to_date}"
}
show.("before")
if shop.approved_for_email
  puts "already approved; nothing written"
else
  shop.update!(approved_for_email: true)
  show.("after")
end
