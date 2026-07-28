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
# An ad-hoc, project-wide time audit an admin can open on any project, independent of the ship
# pipeline. Deliberately holds no ship reference and no association to TimeAuditReview: saving one
# never touches approved hours, koi/gold, Airtable, or any review queue. It is a scratchpad only.
class ProjectTimeAudit < ApplicationRecord
  TOKEN_BYTES = 24

  has_paper_trail

  belongs_to :project
  belongs_to :created_by, class_name: "User"
  belongs_to :last_edited_by, class_name: "User", optional: true # nil until someone saves

  validates :token, presence: true, uniqueness: true

  before_validation :generate_token, on: :create

  scope :recent, -> { order(created_at: :desc) }

  # The share URL is the credential, so paths must be keyed by the random token rather than the
  # sequential id — otherwise the link would be trivially guessable from any other audit's URL.
  def to_param
    token
  end

  def computed_hours
    return nil unless computed_seconds
    (computed_seconds / 3600.0).round(2)
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(TOKEN_BYTES)
  end
end
