class CreateProjectTimeAudits < ActiveRecord::Migration[8.1]
  def change
    # Ad-hoc, project-wide time audits opened by admins. Deliberately has no ship_id and no
    # link to time_audit_reviews — nothing here feeds approved hours, koi, or Airtable.
    create_table :project_time_audits do |t|
      t.references :project, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :last_edited_by, foreign_key: { to_table: :users }
      t.string :token, null: false
      t.string :label
      t.jsonb :annotations, null: false, default: {}
      t.integer :computed_seconds
      t.datetime :saved_at
      t.timestamps
    end

    # The URL token is the only credential on the share link — it must be unique and indexed
    # because every show/update lookup is by token rather than id.
    add_index :project_time_audits, :token, unique: true
  end
end
