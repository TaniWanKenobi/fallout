class Admin::ProjectTimeAuditsController < Admin::ApplicationController
  include TimeAuditSerialization
  include ReviewerNoteSerialization

  # No index action on this controller — ApplicationController registers verify_authorized with
  # `except: :index` and verify_policy_scoped with `only: :index`, both of which raise
  # ActionNotFound here. Every action below calls `authorize` explicitly instead.
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  before_action :set_audit, only: %i[ show update destroy ]

  def create
    project = Project.find(params[:project_id])
    @audit = ProjectTimeAudit.new(project: project, created_by: current_user, label: label_param)
    authorize @audit # Admin-only — see ProjectTimeAuditPolicy#create?
    @audit.save!

    redirect_to admin_project_time_audit_path(@audit)
  end

  def show
    authorize @audit # Share-link holders must still be an admin or time auditor

    project = @audit.project
    entries = project.journal_entries.kept
      .includes(:user, images_attachments: :blob, recordings: :recordable)
      .order(created_at: :asc)

    # Renders the ship time audit page in `project` mode: same annotation UI, no ship, no claim,
    # no decision — see app/frontend/pages/admin/reviews/time_audits/show.tsx.
    render inertia: "admin/reviews/time_audits/show", props: {
      mode: "project",
      review: serialize_audit_as_review(@audit),
      project: serialize_ta_project_context(project),
      new_entries: entries.map { |je| serialize_ta_journal_entry(je) },
      previous_entries: [],
      sibling_statuses: nil,
      reviewer_notes: InertiaRails.defer { serialize_reviewer_notes(project) },
      reviewer_notes_path: admin_project_reviewer_notes_path(project),
      project_flagged: project.flagged?,
      can: { update: policy(@audit).update?, destroy: policy(@audit).destroy? },
      skip: nil,
      heartbeat_path: nil, # No claim to keep alive — these sessions are never queued
      next_path: nil,
      index_path: admin_project_path(project),
      update_path: admin_project_time_audit_path(@audit),
      update_key: "project_time_audit",
      audit: serialize_audit(@audit)
    }
  end

  def update
    authorize @audit

    @audit.last_edited_by = current_user
    @audit.saved_at = Time.current
    if @audit.update(audit_params)
      render json: { ok: true, computed_seconds: @audit.computed_seconds }
    else
      render json: { errors: @audit.errors.messages }, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @audit # Admin-only — revokes the share link
    project = @audit.project
    @audit.destroy! # Hard delete: a revoked link must stop resolving, and the record holds no reviewable data
    redirect_to admin_project_path(project), notice: "Audit session deleted."
  end

  private

  def set_audit
    @audit = ProjectTimeAudit.includes(:project).find_by!(token: params[:token])
  end

  def label_param
    params.dig(:project_time_audit, :label).presence
  end

  def audit_params
    permitted = params.require(:project_time_audit).permit(:computed_seconds, :label)
    if params.dig(:project_time_audit, :annotations)
      raw = params[:project_time_audit][:annotations]&.to_unsafe_h
      # Only allow the expected { "recordings" => { "<id>" => { ... } } } structure
      permitted[:annotations] = raw.is_a?(Hash) ? raw.slice("recordings") : {}
    end
    permitted.to_h
  end

  # Shaped like TimeAuditReview so the shared page can consume it unchanged. `ship_id` is nil and
  # the status is always "pending" — an ad-hoc audit never reaches a terminal review state.
  def serialize_audit_as_review(audit)
    {
      id: audit.id,
      ship_id: nil,
      status: "pending",
      feedback: nil,
      approved_public_seconds: audit.computed_seconds,
      annotations: audit.annotations,
      reviewer_display_name: audit.created_by.display_name,
      created_at: audit.created_at.strftime("%B %d, %Y")
    }
  end

  def serialize_audit(audit)
    {
      token: audit.token,
      label: audit.label,
      share_url: admin_project_time_audit_url(audit),
      created_by_display_name: audit.created_by.display_name,
      last_edited_by_display_name: audit.last_edited_by&.display_name,
      computed_hours: audit.computed_hours,
      saved_at: audit.saved_at&.iso8601,
      created_at: audit.created_at.strftime("%b %d, %Y")
    }
  end
end
