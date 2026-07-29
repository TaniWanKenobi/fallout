# frozen_string_literal: true

require "csv"

namespace :shop do
  desc <<~DESC
    Backfill ShopOrder#structured_address from legacy_address for existing orders.

    The pre-refactor address picker stored a lossy formatted blob (legacy_address) that
    dropped the street line. This task recovers the full structured address by matching
    each order's legacy blob back to the user's HCA unified-identity address (exact-blob
    first, then a street-insensitive match on name + city/state/postal/country, then a
    single-address fallback) and writes the HCA-shaped hash to structured_address.

    Orders whose address can't be resolved from HCA (dead token, address deleted/changed,
    ambiguous) are LEFT UNTOUCHED (they keep falling back to legacy_address for display)
    and written to a report CSV for manual resolution — the street is unrecoverable from
    our own data because the legacy blob never stored it.

    Idempotent: only processes orders with a legacy_address and no structured_address yet.
    Writes go through the model so JSON serialization + encryption apply. Changing
    structured_address creates no paper_trail version (it's a skipped PII column).

    Options (ENV):
      DRY_RUN=1      Default. Resolve + report only, no writes. Set DRY_RUN=0 to persist.
      INCLUDE_FUZZY=1  Also write lower-confidence matches (street-insensitive / single-
                       address fallback, where the HCA address may have changed since the
                       order). Off by default: those are reported for manual review instead.
      THREADS=20     Concurrent HCA identity fetches (default 20).
      LIMIT=N        Only process the first N orders (testing).
      VERBOSE=1      Per-order log instead of a live counter.
      OUTPUT=...     Override the report CSV path.

    Examples:
      bin/rake shop:backfill_structured_addresses            # dry run
      bin/rake shop:backfill_structured_addresses DRY_RUN=0  # persist
  DESC
  task backfill_structured_addresses: :environment do
    dry_run = ENV.fetch("DRY_RUN", "1") != "0"
    include_fuzzy = ENV["INCLUDE_FUZZY"] == "1"
    threads = Integer(ENV.fetch("THREADS", "20"))
    verbose = ENV["VERBOSE"] == "1"
    limit = ENV["LIMIT"]&.to_i

    scope = ShopOrder.where.not(legacy_address: nil).where(structured_address: nil).includes(:user).order(:id)
    scope = scope.limit(limit) if limit&.positive?
    orders = scope.to_a
    users = orders.map(&:user).uniq(&:id)

    output = ENV["OUTPUT"].presence ||
      Rails.root.join("tmp", "backfill_unresolved_#{Time.current.strftime('%Y%m%d_%H%M%S')}.csv").to_s

    puts "Mode: #{dry_run ? 'DRY RUN (no writes)' : 'WRITE'}   Fuzzy matches: #{include_fuzzy ? 'WRITE' : 'report-only'}"
    puts "Orders to backfill: #{orders.size}   Distinct users: #{users.size}   Threads: #{threads}"
    puts ""

    # Preload HCA identities across a thread pool (pure HTTP, no DB access in workers).
    identities = {}
    mutex = Mutex.new
    queue = Queue.new
    users.each { |u| queue << u }
    done = 0
    total = users.size
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    workers = Array.new([ threads, total ].min.clamp(1, threads)) do
      Thread.new do
        loop do
          user = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          ident = backfill_fetch_identity(user)
          mutex.synchronize { identities[user.id] = ident; done += 1 }
        end
      end
    end
    reporter = Thread.new do
      until mutex.synchronize { done } >= total
        snap = mutex.synchronize { done }
        print format("\r  identities %d/%d   ", snap, total) unless verbose
        sleep 0.5
      end
    end
    workers.each(&:join)
    reporter.join
    puts "" unless verbose

    written = 0
    counts = Hash.new(0)
    review = []
    orders.each_with_index do |order, i|
      addr, kind = backfill_classify(identities[order.user_id], order.legacy_address)
      counts[kind] += 1
      # :exact is high-confidence; :loose/:single may reflect an HCA address changed since
      # the order, so they're report-only unless INCLUDE_FUZZY is set.
      writable = addr && (kind == :exact || include_fuzzy)
      review << backfill_review_row(order, kind, addr) if addr && kind != :exact
      review << backfill_review_row(order, kind, nil) if addr.nil?

      if writable && !dry_run
        begin
          # validate: false — we only add structured_address; current validation rules
          # must not block backfilling legacy rows that predate them (e.g. selected_dates).
          order.structured_address = backfill_structured_from(addr)
          order.save!(validate: false)
          written += 1
        rescue => e
          counts[:write_error] += 1
          review << backfill_review_row(order, :write_error, addr, "#{e.class}: #{e.message}")
        end
      elsif writable
        written += 1 # would-write (dry run)
      end
      puts "  #{order.id} #{kind}#{writable ? ' [write]' : ''}" if verbose
      print format("\r  orders %d/%d  exact=%d loose=%d single=%d none=%d   ", i + 1, orders.size, counts[:exact], counts[:loose], counts[:single], counts[:none]) unless verbose
    end
    puts "" unless verbose

    unless review.empty?
      CSV.open(output, "w") do |csv|
        csv << %w[order_id user_id email state item match_kind proposed_line_1 proposed_structured legacy_address note]
        review.each { |r| csv << r }
      end
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    puts "\nDone in #{elapsed.round}s. #{dry_run ? '(DRY RUN — nothing written)' : ''}"
    puts "  exact (auto): #{counts[:exact]}   loose: #{counts[:loose]}   single: #{counts[:single]}   none: #{counts[:none]}"
    puts "  #{dry_run ? 'Would write' : 'Written'}: #{written}  (#{include_fuzzy ? 'incl. fuzzy' : 'exact only; fuzzy report-only'})"
    puts "  Review report (#{review.size} rows): #{output}" unless review.empty?
    puts "\nRe-run with DRY_RUN=0 to persist#{include_fuzzy ? '' : '; add INCLUDE_FUZZY=1 to also write the fuzzy matches'}." if dry_run
  end

  def backfill_fetch_identity(user)
    user.hca_identity || :no_identity
  rescue HcaService::InvalidToken
    :dead_token
  rescue StandardError => e
    Rails.logger.warn("shop:backfill — user #{user.id} identity failed: #{e.class}: #{e.message}")
    :error
  end

  # Returns [address_hash, kind] where kind is :exact (blob matches current HCA exactly),
  # :loose (matched by city/postal/country — street may have changed), :single (user's one
  # address, used as a last resort), or :none (no identity / no candidate).
  def backfill_classify(identity, blob)
    return [ nil, :none ] unless identity.is_a?(Hash) && identity["addresses"].is_a?(Array)

    addrs = identity["addresses"]
    exact = addrs.find { |a| backfill_hca_blob(a) == blob }
    return [ exact, :exact ] if exact

    norm = blob.to_s.downcase
    cands = addrs.select { |a| [ a["city"], a["postal_code"], a["country"] ].all? { |v| v.present? && norm.include?(v.to_s.strip.downcase) } }
    return [ (cands.find { |a| a["primary"] } || cands.first), :loose ] if cands.any?

    return [ addrs.first, :single ] if addrs.one?

    [ nil, :none ]
  end

  # Replicates the pre-refactor ShopOrdersController#hca_formatted_addresses format
  # (including the addr["address"] key bug) so legacy blobs can be matched.
  def backfill_hca_blob(addr)
    [
      [ addr["first_name"], addr["last_name"] ].compact.join(" ").presence,
      addr["address"],
      addr["line_2"].presence,
      [ addr["city"], addr["state"], addr["postal_code"] ].compact.join(", "),
      addr["country"],
      addr["phone"].presence
    ].compact.join("\n")
  end

  def backfill_structured_from(addr)
    {
      "first_name" => addr["first_name"], "last_name" => addr["last_name"],
      "line_1" => addr["line_1"].presence || addr["address"].presence,
      "line_2" => addr["line_2"].presence,
      "city" => addr["city"], "state" => addr["state"],
      "postal_code" => addr["postal_code"], "country" => addr["country"],
      "hca_address_id" => addr["id"]
    }.compact
  end

  def backfill_review_row(order, kind, addr, note = nil)
    structured = addr ? backfill_structured_from(addr) : nil
    [ order.id, order.user_id, order.user&.email, order.state, order.shop_item&.name,
      kind, structured&.dig("line_1"), structured&.to_json, order.legacy_address, note ]
  end
end
