# Serializers shared by the ship time audit queue (Admin::Reviews::TimeAuditsController) and the
# ad-hoc project audit (Admin::ProjectTimeAuditsController). Both render the same Inertia page, so
# the payload shape must stay identical.
#
# Method names are prefixed `ta_`/`serialize_ta_` on purpose: Admin::Reviews::BaseController has
# same-named serializers with different arities for the RC/DR/BR queues, and shadowing those by
# inclusion order would be a silent trap.
module TimeAuditSerialization
  extend ActiveSupport::Concern

  private

  # The time audit frontend applies stretch_multiplier itself, so the raw video duration is
  # returned here — multiplying it first would double-count YouTube time.
  def ta_recording_duration(recording)
    case recording.recordable
    when LookoutTimelapse, LapseTimelapse then recording.recordable.duration.to_i
    when YouTubeVideo then recording.recordable.duration_seconds.to_i
    else 0
    end
  end

  # `ship` is nil for a standalone project audit, where every kept entry is in scope by
  # definition — so `in_ship` is true rather than compared against a ship that doesn't exist.
  def serialize_ta_journal_entry(journal_entry, ship = nil)
    {
      id: journal_entry.id,
      content_html: helpers.render_user_markdown(journal_entry.content.to_s),
      images: journal_entry.images.map { |img| url_for(img) },
      author_display_name: journal_entry.user.display_name,
      author_avatar: journal_entry.user.avatar,
      created_at: journal_entry.created_at.strftime("%b %d, %Y"),
      created_at_iso: journal_entry.created_at.iso8601,
      recordings: journal_entry.recordings.map { |r| serialize_ta_recording(r) },
      total_duration: journal_entry.recordings.sum { |r| ta_recording_duration(r) },
      in_ship: ship.nil? || journal_entry.ship_id == ship.id # Entry was claimed by the ship under review (vs an older ship)
    }
  end

  def serialize_ta_recording(recording)
    recordable = recording.recordable
    base = {
      id: recording.id,
      type: recording.recordable_type,
      duration: ta_recording_duration(recording),
      name: recordable.try(:name) || recordable.try(:title) || "Recording",
      inactive_segments: recordable.try(:inactive_segments) || [],
      inactive_percentage: recordable.try(:inactive_percentage),
      activity_checked: recordable.try(:activity_checked_at).present?
    }

    case recordable
    when LookoutTimelapse
      base.merge(playback_url: recordable.playback_url, thumbnail_url: recordable.thumbnail_url)
    when LapseTimelapse
      base.merge(playback_url: recordable.playback_url, thumbnail_url: recordable.thumbnail_url)
    when YouTubeVideo
      if recordable.timelapse_ready?
        # Processed: present like a Lapse/Lookout timelapse — native player + 60× billing.
        base.merge(
          timelapse_ready: true,
          playback_url: youtube_timelapse_service.presigned_playback_url(recordable),
          thumbnail_url: recordable.thumbnail_url
        )
      else
        base.merge(
          timelapse_ready: false,
          recordable_id: recordable.id, # YouTubeVideo record id for admin refetch action
          video_id: recordable.video_id,
          thumbnail_url: recordable.thumbnail_url,
          yt_duration_seconds: recordable.duration_seconds # used as timeline fallback before YT player loads
        )
      end
    else
      base
    end
  end

  def serialize_ta_project_context(project)
    {
      id: project.id,
      name: project.name,
      description: project.description,
      repo_link: project.repo_link,
      demo_link: project.demo_link,
      user_id: project.user_id,
      user_display_name: project.user.display_name,
      user_avatar: project.user.avatar,
      collaborators: project.collaborator_users.map { |u| { id: u.id, display_name: u.display_name, avatar: u.avatar } }
    }
  end

  # Memoized so a request serializing many recordings reuses one R2 signer (presigning is local, no network).
  def youtube_timelapse_service
    @youtube_timelapse_service ||= YouTubeTimelapseService.new
  end
end
