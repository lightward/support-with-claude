# Approve a Mechanic shop for sending email. Runs in mechanic-api production through prod_read.sh --write, with Isaac's
# go on every run (no standing go, on purpose: approval commits Lightward to sending someone else's mail, without limit,
# so a Lightward human is part of each one):
#   prod_read.sh mechanic ~/dev/support-with-claude/bin/mechanic_approve_email.rb --write SHOP=<name>.myshopify.com
# Prints the state before and after; writes nothing if the shop is already approved.
#
# SENDER=<address> also approves the shop's custom sender, the admin form's approved_email_from_address, and only the
# one the merchant set themselves (custom_email_from_address). Saving it creates the sender's domain in Postmark
# (EmailConcern#ensure_postmark_domain, a before_save), an outside write a rolled-back run can't undo, so the sender
# is only saved with APPLY=1; without it, the run says what it would do. Its DNS records then show in Mechanic's email
# settings, and mail goes from the default address until the domain is verified.
domain = ENV.fetch("SHOP")
sender = ENV["SENDER"]&.downcase
apply = ENV["APPLY"] == "1"
shop = Shop.find_by!(shopify_domain: domain)
show = ->(label) {
  shop.reload
  puts "#{label}: approved_for_email=#{shop.approved_for_email} custom_sender=#{shop.custom_email_from_address.inspect} " \
       "approved_sender=#{shop.approved_email_from_address.inspect} sends_from=#{(shop.email_from_address rescue "?")} " \
       "plan=#{shop.try(:shopify_plan_name)} created=#{shop.created_at.to_date}"
}
show.("before")
if sender && sender != shop.custom_email_from_address&.downcase
  abort "SENDER #{sender} isn't the custom sender this shop set (#{shop.custom_email_from_address.inspect}); nothing written"
end
if shop.approved_for_email
  puts "already approved; nothing written"
else
  shop.update!(approved_for_email: true)
  show.("after approval")
end
if sender
  if shop.approved_email_from_address&.downcase == sender
    puts "sender already approved; nothing written"
  elsif apply
    shop.update!(approved_email_from_address: shop.custom_email_from_address)
    show.("after sender")
  else
    puts "would approve sender #{sender} (and create its domain in Postmark); rerun with APPLY=1 to do it"
  end
end
