#!/bin/bash
# Which shops a sender belongs to, from production, read-only: for a ticket that names no store (no Beacon, no sidebar
# store details, a signature link that goes elsewhere). Locksmith by default; --mechanic for Mechanic.
#
#   find_shop.sh [--mechanic] <email or domain>
#
# An email matches exactly (shop email on file, or a known staff member's email). A domain matches emails at that
# domain and shops whose primary domain is it or a subdomain of it. Prints each shop's myshopify domain and how it
# matched, never anyone's email; follow up with support_shop.sh for the shop itself. Written after #119834 and #119806
# (2026-10-28), where a hand-written lookup needed a go and one shop couldn't be placed at all.
#
# It runs through prod_read.sh like any other read, so it needs a go unless Isaac extends the standing one to it.
set -euo pipefail
app=locksmith
if [[ "${1:-}" == "--mechanic" ]]; then app=mechanic; shift; fi
needle="${1:?usage: find_shop.sh [--mechanic] <email or domain>}"
needle=$(tr '[:upper:]' '[:lower:]' <<<"$needle")
[[ "$needle" =~ ^([a-z0-9._-]+@)?[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || { echo "not an email or domain: $needle" >&2; exit 2; }

script=$(mktemp -t find_shop.XXXXXX)
trap 'rm -f "$script"' EXIT
cat > "$script" <<'RUBY'
needle = ENV.fetch("NEEDLE")
matches = Hash.new { |h, k| h[k] = [] }
if needle.include?("@")
  Shop.where("lower(shopify_email) = ?", needle).pluck(:shopify_domain).each { |d| matches[d] << "shop email" }
  shop_ids = StaffMember.where("lower(email) = ?", needle).distinct.pluck(:shop_id)
  Shop.where(id: shop_ids).pluck(:shopify_domain).each { |d| matches[d] << "staff member" }
else
  at = "%@#{needle}"
  Shop.where("lower(shopify_email) LIKE ?", at).pluck(:shopify_domain).each { |d| matches[d] << "shop email at #{needle}" }
  shop_ids = StaffMember.where("lower(email) LIKE ?", at).distinct.pluck(:shop_id)
  Shop.where(id: shop_ids).pluck(:shopify_domain).each { |d| matches[d] << "staff at #{needle}" }
  Shop.where("lower(shopify_primary_domain) = ? OR lower(shopify_primary_domain) LIKE ?", needle, "%.#{needle}")
    .pluck(:shopify_domain).each { |d| matches[d] << "primary domain" }
end
if matches.empty?
  puts "no shops match #{needle}"
else
  matches.sort.each { |domain, how| puts "#{domain}: #{how.uniq.join(", ")}" }
end
RUBY
"$(dirname "$0")/prod_read.sh" "$app" "$script" "NEEDLE=$needle"
