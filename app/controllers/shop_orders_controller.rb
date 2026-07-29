class ShopOrdersController < ApplicationController
  # No index action — blanket skip required to avoid AbstractController::ActionNotFound
  # from ApplicationController's `after_action :verify_authorized, except: :index`
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  before_action :set_shop_item, only: %i[new create show]
  before_action :require_enabled_item, only: %i[new create] # Only block orders on unavailable items, not viewing existing ones

  def index
    @shop_orders = policy_scope(ShopOrder).includes(:shop_item).order(created_at: :desc)
    skip_authorization # Scoping enforces access; no single record to authorize

    render inertia: "shop_orders/index", props: {
      orders: @shop_orders.map do |o|
        {
          id: o.id,
          state: o.state,
          frozen_price: o.frozen_price,
          quantity: o.quantity,
          created_at: o.created_at.strftime("%b %d, %Y"),
          shop_item: {
            id: o.shop_item.id,
            name: o.shop_item.name,
            image_url: o.shop_item.image_url,
            currency: o.shop_item.currency
          }
        }
      end
    }
  end

  def show
    @shop_order = @shop_item.shop_orders.find(params[:id])
    authorize @shop_order

    render inertia: "shop_orders/show", props: {
      shop_item: { id: @shop_item.id, name: @shop_item.name, image_url: @shop_item.image_url, currency: @shop_item.currency },
      order: {
        id: @shop_order.id,
        state: @shop_order.state,
        frozen_price: @shop_order.frozen_price,
        quantity: @shop_order.quantity,
        created_at: @shop_order.created_at.strftime("%b %d, %Y")
      },
      just_purchased: flash[:just_purchased].present?
    }
  end

  def new
    @shop_order = @shop_item.shop_orders.build(user: current_user)
    authorize @shop_order

    # Koi items can be paid with koi and/or gold (1 koi = 1 gold); gold items are gold-only.
    affordable = @shop_item.currency == "gold" ? current_user.gold >= @shop_item.price : (current_user.koi + current_user.gold) >= @shop_item.price
    unless affordable
      needed = @shop_item.currency == "gold" ? "gold" : "koi or gold"
      return redirect_to "/shop", inertia: { errors: { base: [ "You don't have enough #{needed} to buy this item" ] } }
    end

    render inertia: "shop_orders/new", props: {
      shop_item: serialize_shop_item(@shop_item),
      koi_balance: current_user.koi,
      gold_balance: current_user.gold,
      hca_addresses: @shop_item.requires_shipping? ? hca_formatted_addresses : []
    }
  end

  def create
    structured_address = nil
    if @shop_item.requires_shipping?
      raw_addresses = hca_addresses_raw
      index = params[:address_index].to_i
      selected = (index >= 0 && index < raw_addresses.length) ? raw_addresses[index] : nil # Reject negative/out-of-bounds indices

      unless selected.present?
        return redirect_back fallback_location: new_shop_item_shop_order_path(@shop_item),
          inertia: { errors: { base: [ "A valid shipping address is required" ] } }
      end
      structured_address = structured_address_from(selected)

      phone = params[:phone].to_s.strip
      unless phone.present?
        return redirect_back fallback_location: new_shop_item_shop_order_path(@shop_item),
          inertia: { errors: { base: [ "A phone number is required" ] } }
      end
    end

    quantity = params[:quantity].to_i
    quantity = 1 if quantity < 1

    selected_dates = []
    if @shop_item.requires_date_selection?
      selected_dates = Array(params[:selected_dates]).map(&:to_s).select { |d| ShopOrder::VALID_SUMMIT_DATES.include?(d) }
      unless selected_dates.length == quantity
        return redirect_back fallback_location: new_shop_item_shop_order_path(@shop_item),
          inertia: { errors: { selected_dates: [ "number of dates selected must match quantity" ] } }
      end
    end

    @shop_order = @shop_item.shop_orders.build(structured_address: structured_address, phone: phone, quantity: quantity, selected_dates: selected_dates, user: current_user)
    authorize @shop_order

    # Lock the user row to prevent concurrent orders from double-spending currency
    saved = current_user.with_lock do
      @shop_item.reload # Re-read current price inside the lock
      if @shop_item.currency == "hours"
        @shop_order.errors.add(:base, "This item cannot be purchased directly")
        next false
      end

      @shop_order.frozen_price = @shop_item.price # Freeze the price read inside the lock
      @shop_order.quantity = quantity
      # split_cost computes the koi-first split and user_can_afford validates affordability,
      # both reading the live balance inside the lock so concurrent orders can't double-spend.
      if @shop_order.save
        current_user.increment!(:streak_freezes, quantity) if @shop_item.grants_streak_freeze?
        true
      else
        false
      end
    end

    if saved
      # Airtable sync is handled by AirtableSyncJob (ShopOrder is in CLASSES_TO_SYNC),
      # not inline here — a request cut off mid-sync would otherwise leave data unsynced.
      redirect_to shop_item_shop_order_path(@shop_item, @shop_order), flash: { just_purchased: true }
    else
      redirect_back fallback_location: new_shop_item_shop_order_path(@shop_item),
        inertia: { errors: @shop_order.errors.messages }
    end
  end

  private

  def set_shop_item
    @shop_item = ShopItem.find(params[:shop_item_id])
  end

  def require_enabled_item
    raise ActiveRecord::RecordNotFound unless @shop_item.available?
  end

  # Raw HCA address hashes (HCA identity shape) — the source of truth for both the
  # picker display and the structured_address stored on the order. Indexed by the
  # address_index the frontend submits, so this must stay in the same order as the display.
  def hca_addresses_raw
    if Rails.env.development?
      return [ { "first_name" => "Test", "last_name" => "User", "line_1" => "123 Test Street",
                 "city" => "Toronto", "state" => "ON", "postal_code" => "M5V 1A1", "country" => "Canada" } ]
    end

    current_user.hca_identity&.dig("addresses") || []
  end

  def hca_formatted_addresses
    hca_addresses_raw.map { |addr| format_hca_address(addr) }
  end

  # HCA returns the street as line_1 (older records used "address"); fall back so the
  # street line is never dropped from the display.
  def format_hca_address(addr)
    [
      [ addr["first_name"], addr["last_name"] ].filter_map(&:presence).join(" ").presence,
      addr["line_1"].presence || addr["address"].presence,
      addr["line_2"].presence,
      [ addr["city"], addr["state"], addr["postal_code"] ].filter_map(&:presence).join(", ").presence,
      addr["country"].presence,
      addr["phone"].presence
    ].compact.join("\n")
  end

  # Maps a raw HCA address to the structured hash persisted on the order.
  def structured_address_from(addr)
    {
      "first_name" => addr["first_name"], "last_name" => addr["last_name"],
      "line_1" => addr["line_1"].presence || addr["address"].presence,
      "line_2" => addr["line_2"].presence,
      "city" => addr["city"], "state" => addr["state"],
      "postal_code" => addr["postal_code"], "country" => addr["country"],
      "hca_address_id" => addr["id"]
    }.compact
  end

  def serialize_shop_item(item)
    { id: item.id, name: item.name, description: item.description, price: item.price, image_url: item.image_url, currency: item.currency, requires_shipping: item.requires_shipping?, requires_date_selection: item.requires_date_selection? }
  end
end
