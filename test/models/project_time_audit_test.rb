# == Schema Information
#
# Table name: project_time_audits
#
#  id                :bigint           not null, primary key
#  annotations       :jsonb            not null
#  computed_seconds  :integer
#  label             :string
#  saved_at          :datetime
#  token             :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  created_by_id     :bigint           not null
#  last_edited_by_id :bigint
#  project_id        :bigint           not null
#
# Indexes
#
#  index_project_time_audits_on_created_by_id      (created_by_id)
#  index_project_time_audits_on_last_edited_by_id  (last_edited_by_id)
#  index_project_time_audits_on_project_id         (project_id)
#  index_project_time_audits_on_token              (token) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (created_by_id => users.id)
#  fk_rails_...  (last_edited_by_id => users.id)
#  fk_rails_...  (project_id => projects.id)
#
require "test_helper"

class ProjectTimeAuditTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
