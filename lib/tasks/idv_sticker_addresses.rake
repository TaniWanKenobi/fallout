# frozen_string_literal: true

require "csv"

namespace :idv do
  desc <<~DESC
    Export shipping addresses for identity-verified users (the "idv sticker" list).

    Selects full (non-trial), non-discarded users who are identity-gated —
    verification_status == "verified" AND has_hca_address — then fetches each
    user's HCA unified identity to pull their primary address. Age is computed
    live from the identity birthday; by default only users aged <= MAX_AGE (18,
    i.e. non-adults) are exported, matching the original May 2026 export.

    Addresses are NOT stored locally, so this hits HCA /me once per candidate.
    /me is slow, so fetches run across a thread pool (default 20). Users are
    preloaded into memory first, so worker threads do pure HTTP with no DB access.
    Rows are collected then written sorted by user_id (deterministic output);
    HCA-only failures (dead token / no address) are skipped and counted. Output
    uses the standard CSV library, so free-text address fields are always quoted.

    Options (ENV):
      THREADS=20            Concurrent HCA fetches (default 20)
      MAX_AGE=18            Max age (inclusive) to include (default 18)
      INCLUDE_ADULTS=1      Disable the age filter entirely
      LIMIT=50              Only process the first N candidates (for testing)
      VERBOSE=1             Print a line per user instead of a live counter
      OUTPUT=/path/to.csv   Override output path

    Examples:
      bin/rake idv:sticker_addresses
      bin/rake idv:sticker_addresses THREADS=30
      bin/rake idv:sticker_addresses LIMIT=25 VERBOSE=1
      bin/rake idv:sticker_addresses INCLUDE_ADULTS=1
  DESC
  task sticker_addresses: :environment do
    threads = Integer(ENV.fetch("THREADS", "20"))
    max_age = Integer(ENV.fetch("MAX_AGE", "18"))
    include_adults = ENV["INCLUDE_ADULTS"] == "1"
    verbose = ENV["VERBOSE"] == "1"
    limit = ENV["LIMIT"]&.to_i

    headers = %w[
      user_id email
      address_first_name address_last_name
      profile_first_name profile_last_name
      phone address_line_1 address_line_2
      city state country postal_code
      birthday age
    ]

    output = ENV["OUTPUT"].presence ||
      Rails.root.join("tmp", "idv_sticker_addresses_#{Time.current.strftime('%Y%m%d_%H%M%S')}.csv").to_s

    scope = User
      .where(type: nil, discarded_at: nil, verification_status: "verified", has_hca_address: true)
      .order(:id)
    scope = scope.limit(limit) if limit&.positive?

    # Preload everything worker threads need up front so the pool does pure HTTP
    # (user.hca_identity + already-loaded attributes) and never touches the DB —
    # sidesteps connection-pool contention across threads entirely.
    users = scope.to_a
    total = users.size

    puts "Candidates (verified + has_hca_address, full users): #{total}"
    puts "Age filter: #{include_adults ? 'disabled' : "age <= #{max_age}"}"
    puts "Threads: #{threads}"
    puts "Writing to #{output}"
    puts ""

    queue = Queue.new
    users.each { |u| queue << u }

    rows = []
    counts = { done: 0, written: 0, no_identity: 0, no_address: 0, age_filtered: 0, error: 0 }
    mutex = Mutex.new
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    workers = Array.new(threads) do
      Thread.new do
        loop do
          user = begin
            queue.pop(true)
          rescue ThreadError
            break
          end

          status = process_user(user, include_adults, max_age)

          mutex.synchronize do
            counts[:done] += 1
            counts[status[:code]] += 1
            rows << status[:row] if status[:row]
            puts "  #{user.id} #{user.email} — #{status[:code]}" if verbose
          end
        end
      end
    end

    # Reporter thread: live single-line progress while the pool drains.
    reporter = Thread.new do
      until mutex.synchronize { counts[:done] } >= total
        snap = mutex.synchronize { counts.dup }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        rate = snap[:done] / elapsed if elapsed.positive?
        eta = rate && rate.positive? ? (total - snap[:done]) / rate : nil
        unless verbose
          print format(
            "\r  %d/%d (%.1f%%)  written=%d  no_id=%d  no_addr=%d  age=%d  err=%d  %.1f/s  eta=%s   ",
            snap[:done], total, 100.0 * snap[:done] / total,
            snap[:written], snap[:no_identity], snap[:no_address], snap[:age_filtered], snap[:error],
            rate || 0, eta ? "#{eta.round}s" : "?"
          )
        end
        sleep 0.5
      end
    end

    workers.each(&:join)
    reporter.join

    rows.sort_by! { |r| r[0] }
    CSV.open(output, "w") do |csv|
      csv << headers
      rows.each { |r| csv << r }
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    puts "" unless verbose
    puts "\nDone in #{elapsed.round}s."
    puts "  Written:        #{counts[:written]}"
    puts "  No identity:    #{counts[:no_identity]}"
    puts "  No address:     #{counts[:no_address]}"
    puts "  Age-filtered:   #{counts[:age_filtered]}" unless include_adults
    puts "  Errors:         #{counts[:error]}"
    puts "  File:           #{output}"
  end

  # Fetches one user's HCA identity and returns { code:, row: }. Pure HTTP + in-memory
  # attribute access — safe to call from worker threads (no DB access).
  def process_user(user, include_adults, max_age)
    identity = user.hca_identity
    return { code: :no_identity, row: nil } if identity.blank?

    addresses = identity["addresses"].is_a?(Array) ? identity["addresses"] : []
    addr = addresses.find { |a| a["primary"] } || addresses.first
    return { code: :no_address, row: nil } if addr.blank?

    birthday = identity["birthday"].presence
    age = age_from(birthday)
    return { code: :age_filtered, row: nil } unless include_adults || (age && age <= max_age)

    row = [
      user.id, user.email,
      addr["first_name"], addr["last_name"],
      identity["first_name"], identity["last_name"],
      addr["phone"].presence,
      addr["line_1"].presence || addr["address"],
      addr["line_2"].presence,
      addr["city"], addr["state"], addr["country"], addr["postal_code"],
      birthday, age
    ]
    { code: :written, row: row }
  rescue HcaService::InvalidToken
    # Dead HCA token — no way to fetch this user's address.
    { code: :no_identity, row: nil }
  rescue StandardError => e
    Rails.logger.warn("idv:sticker_addresses — user #{user.id} failed: #{e.class}: #{e.message}")
    { code: :error, row: nil }
  end

  def age_from(birthday_str)
    return nil if birthday_str.blank?

    birthday = Date.parse(birthday_str)
    today = Date.current
    age = today.year - birthday.year
    age -= 1 if today.month < birthday.month || (today.month == birthday.month && today.day < birthday.day)
    age
  rescue ArgumentError
    nil
  end
end
