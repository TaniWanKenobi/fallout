require "test_helper"

class Admin::ProjectTimeAuditsControllerTest < ActionController::TestCase
  tests Admin::ProjectTimeAuditsController

  self.fixture_table_names = [] # Repo fixtures are currently stale (array columns hold "MyString"); build records inline

  setup do
    @admin = create_user(roles: [ "admin" ])
    @auditor = create_user(roles: [ "time_auditor" ])
    @project = Project.create!(user: create_user(roles: [ "time_auditor" ]), name: "Audited project")
  end

  def create_user(roles:)
    id = SecureRandom.hex(6)
    User.create!(
      email: "u#{id}@example.com",
      display_name: "User #{id}",
      avatar: "https://example.com/a.png",
      timezone: "UTC",
      slack_id: "U#{id}",
      hca_id: "hca-#{id}",
      onboarded: true,
      roles: roles
    )
  end

  def sign_in(user)
    @request.session[:user_id] = user.id
  end

  # Request as Inertia so the response is JSON props — the HTML layout needs a vite build
  def inertia_get(action, params)
    @request.headers["X-Inertia"] = "true"
    @request.headers["X-Inertia-Version"] = InertiaRails.configuration.version
    get action, params: params
    JSON.parse(@response.body)["props"]
  end

  test "admin creates an audit and is redirected to its token URL" do
    sign_in(@admin)
    assert_difference -> { ProjectTimeAudit.count }, 1 do
      post :create, params: { project_id: @project.id, project_time_audit: { label: "spot check" } }
    end
    audit = ProjectTimeAudit.last
    assert_redirected_to "/admin/project_audits/#{audit.token}"
    assert_equal @admin, audit.created_by
    assert_equal "spot check", audit.label
    assert audit.token.present?
  end

  test "non-admin time auditor cannot create" do
    sign_in(@auditor)
    assert_no_difference -> { ProjectTimeAudit.count } do
      post :create, params: { project_id: @project.id }
    end
    assert_response :redirect
    assert_equal "You are not authorized to perform this action.", flash[:alert]
  end

  test "time auditor with the link can show and update" do
    audit = ProjectTimeAudit.create!(project: @project, created_by: @admin)
    sign_in(@auditor)

    props = inertia_get(:show, { token: audit.token })
    assert_equal "project", props.fetch("mode")
    assert_nil props.dig("review", "ship_id")
    assert_equal "project_time_audit", props.fetch("update_key")
    assert_equal "/admin/project_audits/#{audit.token}", props.fetch("update_path")
    assert_equal "/admin/projects/#{@project.id}", props.fetch("index_path")
    assert_nil props.fetch("heartbeat_path")
    assert_nil props.fetch("next_path")
    assert_equal [], props.fetch("previous_entries")

    patch :update, params: {
      token: audit.token,
      project_time_audit: { annotations: { "recordings" => { "7" => { "description" => "ok" } }, "junk" => 1 }, computed_seconds: 7200 }
    }, as: :json
    assert_response :success

    audit.reload
    assert_equal({ "recordings" => { "7" => { "description" => "ok" } } }, audit.annotations)
    assert_equal 7200, audit.computed_seconds
    assert_equal @auditor, audit.last_edited_by
    assert audit.saved_at.present?
  end

  test "every kept entry is in scope for a standalone audit" do
    owner = @project.user
    entry = JournalEntry.create!(project: @project, user: owner, content: "did stuff")
    lapse = LapseTimelapse.create!(user: owner, duration: 1800, lapse_timelapse_id: "L#{SecureRandom.hex(4)}",
                                   playback_url: "https://example.com/v.mp4")
    Recording.create!(journal_entry: entry, user: owner, recordable: lapse)
    discarded = JournalEntry.create!(project: @project, user: owner, content: "deleted")
    discarded.discard

    audit = ProjectTimeAudit.create!(project: @project, created_by: @admin)
    sign_in(@admin)
    props = inertia_get(:show, { token: audit.token })

    entries = props.fetch("new_entries")
    assert_equal [ entry.id ], entries.map { |e| e.fetch("id") } # discarded entry excluded
    assert entries.first.fetch("in_ship"), "standalone audit has no ship, so every entry is in scope"
    assert_equal 1800, entries.first.fetch("total_duration")
    assert_equal "LapseTimelapse", entries.first.fetch("recordings").first.fetch("type")
  end

  test "time auditor cannot destroy" do
    audit = ProjectTimeAudit.create!(project: @project, created_by: @admin)
    sign_in(@auditor)
    delete :destroy, params: { token: audit.token }
    assert_equal "You are not authorized to perform this action.", flash[:alert]
    assert ProjectTimeAudit.exists?(audit.id)
  end

  test "staff without the time audit role cannot show even with the link" do
    audit = ProjectTimeAudit.create!(project: @project, created_by: @admin)
    sign_in(create_user(roles: [ "requirements_checker" ]))
    get :show, params: { token: audit.token }
    assert_equal "You are not authorized to perform this action.", flash[:alert]
  end

  test "saving an audit touches nothing in the ship pipeline" do
    audit = ProjectTimeAudit.create!(project: @project, created_by: @admin)
    sign_in(@admin)
    before = TimeAuditReview.order(:id).pluck(:id, :status, :approved_public_seconds, :annotations)
    ships_before = Ship.order(:id).pluck(:id, :status, :approved_public_seconds)

    patch :update, params: {
      token: audit.token,
      project_time_audit: { annotations: { "recordings" => {} }, computed_seconds: 999 }
    }, as: :json
    assert_response :success

    assert_equal before, TimeAuditReview.order(:id).pluck(:id, :status, :approved_public_seconds, :annotations)
    assert_equal ships_before, Ship.order(:id).pluck(:id, :status, :approved_public_seconds)
  end
end
