class AddCertificateTokenToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :certificate_token, :string
    add_index :users, :certificate_token, unique: true
  end
end
