class RenameShopOrderAddressToLegacyAndAddStructured < ActiveRecord::Migration[8.1]
  def change
    # Preserve the existing (encrypted, lossy) formatted-blob addresses under a new name
    # so nothing is lost; new orders write structured_address instead.
    rename_column :shop_orders, :address, :legacy_address
    # Structured HCA-shaped address, stored as encrypted JSON (see ShopOrder). text, not
    # jsonb: the value is ciphertext (PII of minors, encrypted at rest) and never queried.
    add_column :shop_orders, :structured_address, :text
  end
end
