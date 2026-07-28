# Shared by the review queues and the ad-hoc project audit, which both render ProjectNotesWindow.
module ReviewerNoteSerialization
  extend ActiveSupport::Concern

  private

  def serialize_reviewer_notes(project)
    project.reviewer_notes.includes(:user).order(created_at: :desc).map do |note|
      {
        id: note.id,
        body: note.body,
        ship_id: note.ship_id,
        review_stage: note.review_stage,
        author_display_name: note.user.display_name,
        author_avatar: note.user.avatar,
        author_id: note.user_id,
        created_at: note.created_at.iso8601,
        updated_at: note.updated_at.iso8601
      }
    end
  end
end
