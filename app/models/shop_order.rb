# == Schema Information
#
# Table name: shop_orders
#
#  id                 :bigint           not null, primary key
#  admin_note         :text
#  frozen_gold_amount :integer          default(0), not null
#  frozen_koi_amount  :integer          not null
#  frozen_price       :integer          not null
#  legacy_address     :text
#  phone              :text
#  quantity           :integer          default(1), not null
#  selected_dates     :text             default([]), is an Array
#  state              :string           default("pending"), not null
#  structured_address :text
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  shop_item_id       :bigint           not null
#  user_id            :bigint           not null
#
# Indexes
#
#  index_shop_orders_on_shop_item_id  (shop_item_id)
#  index_shop_orders_on_state         (state)
#  index_shop_orders_on_user_id       (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (shop_item_id => shop_items.id)
#  fk_rails_...  (user_id => users.id)
#
class ShopOrder < ApplicationRecord
  VALID_SUMMIT_DATES = %w[2026-06-29 2026-06-30 2026-07-07 2026-07-08].freeze

  # Shipping PII of minors — encrypted at rest. Never queried, so non-deterministic.
  encrypts :phone
  # legacy_address: pre-refactor formatted-blob string (kept for orders not yet backfilled).
  # structured_address: HCA-shaped hash (first_name/last_name/line_1/line_2/city/state/
  # postal_code/country) serialized to JSON. Both hold minors' PII, so both stay encrypted.
  encrypts :legacy_address
  serialize :structured_address, coder: JSON
  encrypts :structured_address

  # Skip PII columns so shipping details aren't duplicated into versions, which a PII deletion of the order wouldn't reach.
  has_paper_trail skip: %i[phone legacy_address structured_address]

  belongs_to :user
  belongs_to :shop_item

  enum :state, { pending: "pending", fulfilled: "fulfilled", rejected: "rejected", on_hold: "on_hold" }, default: "pending"

  before_validation :freeze_price, on: :create
  # Splits the cost koi-first, gold-second (1 koi = 1 gold) — see #split_cost.
  before_validation :split_cost, on: :create

  validates :frozen_price, presence: true, numericality: { greater_than: 0 }
  validates :frozen_koi_amount, presence: true, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :frozen_gold_amount, presence: true, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :quantity, presence: true, numericality: { greater_than: 0, only_integer: true }
  # New orders must capture a structured address for shipping items; legacy_address is
  # only ever populated by the backfill, never by the create flow, so it isn't validated.
  validates :structured_address, presence: true, if: -> { shop_item&.requires_shipping? }, on: :create
  validates :phone, presence: true, if: -> { shop_item&.requires_shipping? }
  validate :phone_digit_count
  validate :selected_dates_valid, if: -> { shop_item&.requires_date_selection? }
  validate :user_can_afford, on: :create

  def self.airtable_sync_base_id
    "appQgtRNTHxDGko9K"
  end

  def self.airtable_sync_table_id
    "tblxnayTCB6r3dyIc"
  end

  def self.airtable_sync_sync_id
    "BumrJ0Rr"
  end

  def self.airtable_sync_field_mappings
    {
      "ID" => :id,
      "User" => ->(o) { o.user_id },
      # Single select in Airtable; the CSV sync source creates the option from the name.
      "Item" => ->(o) { o.shop_item&.name },
      "Quantity" => :quantity,
      "Frozen Price" => :frozen_price,
      "Frozen Gold Amount" => :frozen_gold_amount,
      "Frozen Koi Amount" => :frozen_koi_amount,
      "State" => :state,
      "Created At" => ->(o) { o.created_at&.iso8601 }
    }
  end

  # Human-readable shipping address for display/serialization. Prefers the structured
  # HCA-shaped address (new orders); falls back to the pre-refactor formatted blob
  # (legacy_address) for orders not yet backfilled.
  def address
    return legacy_address if structured_address.blank?

    a = structured_address
    [
      [ a["first_name"], a["last_name"] ].filter_map(&:presence).join(" ").presence,
      a["line_1"].presence,
      a["line_2"].presence,
      [ a["city"], a["state"], a["postal_code"] ].filter_map(&:presence).join(", ").presence,
      a["country"].presence
    ].compact.join("\n")
  end

  private

  def freeze_price
    self.frozen_price ||= shop_item&.price
  end

  # Koi items accept gold too (1 koi = 1 gold): spend the user's available koi first,
  # cover the remainder in gold. Gold-only items can't be paid with koi — koi carries
  # spending restrictions gold doesn't. Hours items aren't charged in either currency.
  # Skips if already computed (0 is truthy in Ruby) so it's idempotent across valid? passes.
  def split_cost
    return if frozen_koi_amount
    return unless shop_item && frozen_price && quantity

    total = frozen_price * quantity
    koi_part = case shop_item.currency
    when "gold", "hours" then 0
    else user ? user.koi.clamp(0, total) : 0
    end
    self.frozen_koi_amount = koi_part
    self.frozen_gold_amount = shop_item.currency == "hours" ? 0 : total - koi_part
  end

  def selected_dates_valid
    dates = Array(selected_dates).reject(&:blank?)
    invalid = dates - VALID_SUMMIT_DATES
    errors.add(:selected_dates, "contains invalid dates") if invalid.any?
    errors.add(:selected_dates, "number of dates selected must match quantity") unless dates.length == quantity
  end

  def phone_digit_count
    return unless phone && shop_item&.requires_shipping?
    errors.add(:phone, "must be a valid phone number") unless phone.gsub(/\D/, "").length.between?(7, 15)
  end

  def user_can_afford
    return unless user && shop_item && frozen_koi_amount && frozen_gold_amount
    return if user.trial? # trial users are blocked at policy level

    if shop_item.currency == "hours"
      errors.add(:base, "This item cannot be purchased directly")
      return
    end

    return if user.koi >= frozen_koi_amount && user.gold >= frozen_gold_amount

    needed = shop_item.currency == "gold" ? "gold" : "koi or gold"
    errors.add(:base, "You don't have enough #{needed} for this purchase")
  end
end
