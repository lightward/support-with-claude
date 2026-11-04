# Cancels a Mechanic shop's due (queued, not yet enqueued) event runs and task runs for the given event topics: Isaac's
# queue-reset playbook, narrowed by topic. Runs already enqueued or running are left alone.
#
#   prod_read.sh mechanic bin/mechanic_cancel_due_runs.rb SHOP=<name>.myshopify.com TOPICS=<topic>:<topic>
#     counts and query plans only (rolled back)
#   prod_read.sh mechanic bin/mechanic_cancel_due_runs.rb --write SHOP=... TOPICS=... APPLY=1
#     cancels, with Isaac's go
#
# Filters on the runs' own denormalized event_topic column, never joining events, so every query stays on the shop's
# small *_on_shop_id_and_run_at_where_due partial index. The write re-applies `due`, so a run a worker claimed between
# the pluck and the update is left alone. Prints counts and plans, never run data.

ActiveRecord::Base.connection.execute("SET statement_timeout = '30s'") # holds under --write too

shop = Shop.find_by!(shopify_domain: ENV.fetch("SHOP"))
topics = ENV.fetch("TOPICS").split(":").map(&:strip).reject(&:empty?)
apply = ENV["APPLY"] == "1"
abort "no topics given" if topics.empty?

puts "shop: #{shop.shopify_domain}"
puts "mode: #{apply ? "APPLY (cancelling)" : "count only"}"

tables = { "event_runs" => [EventRun, shop.event_runs], "task_runs" => [TaskRun, shop.task_runs] }

tables.each do |table, (_, rel)|
  counts = rel.due.group(:event_topic).count.sort_by { |_, n| -n }
  puts "#{table} due, all topics: #{counts.sum { |_, n| n }}"
  counts.first(10).each { |t, n| puts "  #{t.inspect}: #{n}" }
  puts "#{table} enqueued (left alone): #{rel.enqueued.count}"
end

error = "Cancelled by Mechanic staff at #{shop.local_time.iso8601}"

tables.each do |table, (klass, rel)|
  topics.each do |topic|
    scope = rel.due.where(event_topic: topic)
    before = scope.count
    puts "#{table} due for #{topic}: #{before}"

    unless apply
      puts "  plan (count):"
      puts scope.explain.inspect.lines.map { |l| "    #{l}" }.join
      puts "  plan (batch):"
      puts scope.limit(1000).select(:id).explain.inspect.lines.map { |l| "    #{l}" }.join
      next
    end
    next unless before.positive?

    done = 0
    raced = 0
    loop do
      ids = scope.limit(1000).pluck(:id)
      break if ids.empty?

      n = klass.due.where(id: ids).update_all(ok: false, error: error, updated_at: Time.now.utc) # updated_at, so audit and search see the cancel
      done += n
      raced += ids.size - n
    end
    puts "  cancelled: #{done}; raced (left alone): #{raced}; due now: #{scope.count}"
  end
end
