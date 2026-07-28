class CertificateVerificationsController < ApplicationController
  allow_unauthenticated_access only: %i[show] # Certificate QR/link must work for anyone, signed in or not
  allow_trial_access only: %i[show] # Also reachable by a signed-in trial user
  skip_onboarding_redirect only: %i[show] # Public verification page must stay viewable before onboarding
  skip_after_action :verify_authorized # Token-based access, no Pundit resource
  skip_after_action :verify_policy_scoped # No index action; no policy-scoped queries

  def show
    user = User.verified.kept.not_banned.find_by(certificate_token: params[:token])
    return redirect_to root_path, alert: "This certificate link is not valid." if user.nil?

    # Same attribution set (owned + collaborated + credited) the 60h qualification bar uses —
    # see User#projects_attributable_to_self_ids — restricted to listed, kept projects for a public page.
    candidate_projects = Project.kept.listed
      .where(id: user.projects_attributable_to_self_ids)
      .includes(unified_thumbnail_attachment: :blob)
      .to_a
    approved_seconds_by_project = Project.batch_user_approved_seconds(candidate_projects.map(&:id), user)

    # Only show projects with an approved ship — matches the page copy ("evaluated and approved");
    # attributable-but-never-approved projects would otherwise render with 0h.
    projects = candidate_projects.select { |project| approved_seconds_by_project[project.id].to_i.positive? }

    render inertia: "certificate_verifications/show", props: {
      full_name: [ user.first_name, user.last_name ].compact.join(" ").presence || user.display_name,
      avatar: user.avatar,
      projects: projects.map do |project|
        {
          name: project.name,
          description: project.description,
          thumbnail_url: project.unified_thumbnail.attached? ? url_for(project.unified_thumbnail) : nil,
          url: project_path(project),
          approved_hours: (approved_seconds_by_project[project.id].to_i / 3600.0).round(1)
        }
      end
    }
  end
end
