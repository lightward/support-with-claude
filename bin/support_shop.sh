#!/bin/bash
# A Locksmith shop's setup as Markdown, from production: locksmith-api's support report, read-only.
#
#   support_shop.sh <shop>[.myshopify.com] [sender email]
#
# Isaac has given a standing go for these reads (2026-10-20), so the before-acting hook lets this script through
# without a go line. It can only render the report, so the standing go covers exactly that much: anything else in
# production still goes through prod_read.sh, with a go each time.
set -euo pipefail
shop="${1:?usage: support_shop.sh <shop> [sender email]}"
sender="${2:-}"
[[ "$shop" =~ ^[a-z0-9][a-z0-9-]*(\.myshopify\.com)?$ ]] || { echo "not a shop handle: $shop" >&2; exit 2; }
[[ -z "$sender" || "$sender" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$ ]] || { echo "not an email this script accepts: $sender" >&2; exit 2; }
shop="${shop%.myshopify.com}.myshopify.com"

script=$(mktemp -t support_shop.XXXXXX)
trap 'rm -f "$script"' EXIT
cat > "$script" <<'RUBY'
shop = Shop.find_by(shopify_domain: ENV.fetch("SHOP"))
abort("no shop #{ENV.fetch("SHOP")}") unless shop
puts Locksmith::SupportReport.new(shop, sender: ENV["SENDER"].presence).to_markdown
RUBY
"$(dirname "$0")/prod_read.sh" locksmith "$script" "SHOP=$shop" ${sender:+"SENDER=$sender"}
