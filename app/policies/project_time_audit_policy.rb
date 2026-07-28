# frozen_string_literal: true

class ProjectTimeAuditPolicy < ApplicationPolicy
  # Only admins may open an ad-hoc audit on an arbitrary project — creating one is a
  # supervisory action, not part of any reviewer's queue.
  def create?
    admin?
  end

  # The secret URL is the sharing mechanism, but it is not the authorization: the holder must
  # still be an admin or a time auditor, so a leaked link is useless to anyone else.
  def show?
    admin? || time_auditor?
  end

  def update?
    show?
  end

  def destroy?
    admin? # Revoking a share link is admin-only, like creating it
  end

  private

  def time_auditor?
    user&.can_review?(:time_audit)
  end

  class Scope < ApplicationPolicy::Scope
    # Listing audits (on the admin project page) reveals every share link for that project,
    # so it is admin-only — auditors reach a session through the link they were given.
    def resolve
      user&.admin? ? scope.all : scope.none
    end
  end
end
