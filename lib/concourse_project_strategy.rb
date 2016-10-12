class ConcourseProjectStrategy
  def initialize(requester, concourse_authenticator)
    @requester = requester
    @concourse_authenticator = concourse_authenticator
  end

  def create_handler(project)
    ProjectWorkloadHandler.new(project)
  end

  def create_workload(project)
    workload = PollerWorkload.new
    workload.add_job(:concourse_project, project)
    workload
  end

  # returns a request that gets callback/errback assigned to it
  def fetch_status(project, url)
    @concourse_authenticator.authenticate do |session_token|
      request_options = {
          head: {'Set-Cookie' => "ATC-Authorization=Bearer #{session_token}"}
      }

      if project.accept_mime_types.present?
        headers = request_options[:head] || {}
        request_options[:head] = headers.merge('Accept' => project.accept_mime_types)
      end

      request = @requester.initiate_request(url, request_options)

      request.callback do |client|
        yield PollState::SUCCEEDED, client.response

      end

      request.errback do |client|
        yield PollState::FAILED, client.response
      end
    end
  end
end