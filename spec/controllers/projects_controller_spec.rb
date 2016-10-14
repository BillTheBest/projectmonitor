require 'spec_helper'
require 'time'

describe ProjectsController, :type => :controller do
  describe "with a logged in user" do
    before do
      @current_user = create(:user)
      sign_in @current_user
    end

    context "when nested under an aggregate project" do
      it "should scope by aggregate_project_id" do
        expect(Project).to receive(:with_aggregate_project).with('1')
        get :index, aggregate_project_id: 1
      end
    end

    describe "#index" do
      describe 'filtering by tags' do
        let!(:projects) { [create(:jenkins_project, code: "BETA", aggregate_project_id: aggregate_project.id)] }
        let!(:aggregate_project) { create(:aggregate_project, code: "ALPH", enabled: true) }
        let!(:aggregate_projects) { [aggregate_project] }
        let(:tags) { 'bleecker' }

        before do
          aggregate_project.tags.create(name: tags)
        end

        it 'gets a collection of aggregate projects by tag' do
          get :index, tags: tags, format: :json

          expect(assigns(:projects)).to match_array(aggregate_projects)
        end
      end

      describe "limiting the number of displayed projects" do
        it "shows only the desired amount of projects (but all aggregate projects)" do
          project_limit = 1
          get :index, limit: project_limit, format: :json

          expect(assigns(:projects).length).to eq(AggregateProject.displayable.count + project_limit)
        end

        it "shows all projects if the limit is set to 'all'" do
          get :index, limit: 'all', format: :json

          expect(assigns(:projects).length).to eq(AggregateProject.displayable.count + Project.standalone.displayable.count)
        end
      end
    end

    describe "#create" do
      context "when the project is valid" do
        def do_post
          post :create, project: {
            name: 'name',
            type: JenkinsProject.name,
            ci_base_url: 'http://www.example.com',
            ci_build_identifier: 'example'
          }
        end

        it "should create a project of the correct type" do
          expect { do_post }.to change(JenkinsProject, :count).by(1)
        end

        it "should set the project's creator'" do
          do_post
          expect(Project.last.creator).to eq(@current_user)
        end

        it "should set the flash" do
          do_post
          expect(flash[:notice]).to eq('Project was successfully created.')
        end

        it { expect(do_post).to redirect_to edit_configuration_path }

        describe 'and it is a ConcourseProject' do
          it 'should let you save the projects team name' do
            post :create, project: {
                name: 'name',
                type: ConcourseProject.name,
                ci_base_url: 'http://www.example.com',
                ci_build_identifier: 'example',
                concourse_pipeline_name: 'pipeline',
                team_name: 'iad'
            }

            expect(Project.last.team_name).to eq('iad')
          end
        end
      end

      context "when the project is invalid" do
        before { post :create, project: { name: nil, type: JenkinsProject.name} }
        it { is_expected.to render_template :new }
      end
    end

    describe "#update" do
      context "when the project was successfully updated" do
        before { put :update, id: projects(:jenkins_project), project: { name: "new name" } }

        it "should set the flash" do
          expect(flash[:notice]).to eq('Project was successfully updated.')
        end

        it { is_expected.to redirect_to edit_configuration_path }
      end

      context "when the project was not successfully updated" do
        before { put :update, id: projects(:jenkins_project), project: { name: nil } }
        it { is_expected.to render_template :edit }
      end


      describe "feed password" do
        let(:project) { projects(:socialitis).tap {|p| p.auth_password = 'existing password'} }
        subject { project.auth_password }
        before do
          put :update, id: projects(:socialitis).id, password_changed: changed, project: {auth_password: new_password }
          project.reload
        end

        context 'when the password has been changed' do
          let(:changed) { 'true' }

          context 'when the new password is not present' do
            let(:new_password) { nil }
            it { is_expected.to be_nil }
          end
          context 'when the new password is present but empty' do
            let(:new_password) { '' }
            it { is_expected.to be_nil }
          end
          context 'when the new password is not empty' do
            let(:new_password) { 'new password' }
            it { is_expected.to eq(new_password) }
          end
        end

        context 'when the password has not been changed' do
          let(:changed) { 'false' }

          after { it {is_expected.to eq('existing_password')} }

          context 'when the new password is not present' do
            let(:new_password) { nil }
          end
          context 'when the new password is present but empty' do
            let(:new_password) { '' }
          end
          context 'when the new password is not empty' do
            let(:new_password) { 'new_password' }
          end
        end

      end

      describe "changing STI type" do
        subject { put :update, "id"=> project.id, "project" => project_params }
        let!(:project) { create(:team_city_project) }

        context "when the parameters are valid" do
          let(:project_params) { {type: "JenkinsProject", name: "foobar", ci_base_url: "http://foo", ci_build_identifier: "NAMe"} }
          it "should validate as the new type and save the record" do
            subject
            expect(Project.find(project.id).is_a? JenkinsProject).to be true
          end
        end

        context "when the parameters are not valid" do

          let(:project_params) { {type: "SemaphoreProject", semaphore_api_url: nil} }
          it "should validate as the new type and not save the record" do
            subject
            expect(Project.find(project.id).is_a? TeamCityProject).to be true
          end
        end
      end
    end

    describe "#destroy" do
      subject { delete :destroy, id: projects(:jenkins_project) }

      it "should destroy the project" do
        expect { subject }.to change(JenkinsProject, :count).by(-1)
      end

      it "should set the flash" do
        subject
        expect(flash[:notice]).to eq('Project was successfully destroyed.')
      end

      it { is_expected.to redirect_to edit_configuration_path }
    end

    describe "#validate_tracker_project" do
      it "should enqueue a job" do
        project = projects(:jenkins_project)
        expect(TrackerProjectValidator).to receive(:delay) { TrackerProjectValidator }
        expect(TrackerProjectValidator).to receive :validate
        post :validate_tracker_project, { auth_token: "12354", project_id: "98765", id: project.id }
      end
    end

    describe '#validate_build_info' do
      let(:parsed_response) { JSON.parse(post(:validate_build_info, {project: {type: TravisProject}}).body)}

      context 'when the payload is missing' do
        it "returns 422" do
          post :validate_build_info, {}
          expect(response).to be_unprocessable
        end

        it "renders nothing" do
          post :validate_build_info, {}
          expect(response.body).to be_blank
        end
      end

      context 'when the payload is invalid' do
        before(:each) { expect_any_instance_of(ProjectUpdater).to receive(:update).and_return(log_entry) } # SMELL

        let(:log_entry) { PayloadLogEntry.new(status: 'failed', error_type: 'MockExceptionClass', error_text: error_text) }
        let(:error_text) { 'Mock error description'}

        context 'should set success flag to true' do
          subject { parsed_response['status'] }
          it { is_expected.to be false }
        end

        context 'should set error_class to correct exception' do
          subject { parsed_response['error_type'] }
          it { is_expected.to eq('MockExceptionClass') }
        end

        context 'should set error_text to correct text' do
          subject { parsed_response['error_text'] }
          context 'with a short description' do
            it { is_expected.to eq('Mock error description') }
          end

          context 'with a long description' do
            let(:error_text) { 'a'*50000 }
            it { is_expected.to eq('a'*10000) }
          end
        end
      end

      context 'when the payload is valid' do
        before(:each) { expect_any_instance_of(ProjectUpdater).to receive(:update).and_return(log_entry) } # SMELL
        let(:log_entry) { PayloadLogEntry.new(status: 'successful', error_type: nil, error_text: '') }

        context 'should set success flag to false' do
          subject { parsed_response['status'] }
          it { is_expected.to be true }
        end

        context 'should set error_class to nil' do
          subject { parsed_response['error_type'] }
          it { is_expected.to be_nil }
        end

        context 'should set error_text to empty string' do
          subject { parsed_response['error_text'] }
          it { is_expected.to eq('') }
        end
      end

      context "for a project with a saved password" do
        let!(:project) { create(:team_city_project, "auth_password" => "old_password") }

        before do
          expect_any_instance_of(ProjectUpdater).to receive(:update) do |instance, project|
            @project_to_update = project
            project.payload_log_entries.build
          end
        end

        context "when a new password is entered in the form" do
          it "should grab the existing project password" do
            post :validate_build_info, {
              project: project.attributes.merge(auth_password: 'new_password')
            }
            expect(@project_to_update.auth_password).to eq('new_password')
          end
        end

        context "when a new password is not entered in the form" do
          it "should use the saved password to fetch" do
            post :validate_build_info, {project: project.attributes.except('auth_password')}
            expect(@project_to_update.auth_password).to eq('old_password')
          end
        end
      end
    end
  end
end
