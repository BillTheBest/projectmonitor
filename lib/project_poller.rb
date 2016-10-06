#
# Asynchronous IO (via the Reactor model) can be a little confusing, so a bit
# of an explanation is in order:
#
# This poller basically looks for all projects that need updating, then asks
# the project to build a workload, which is a list of jobs that need to be
# completed. A job is essentially a URL that needs to be fetched.
#
# When the complete list of jobs has been completed, the handler is notified and
# the project is updated. The workload model is used as jobs can be completed
# in any order.
#
class ProjectPoller

  def initialize
    @workloads = {}
    @poll_period = 60
    @tracker_poll_period = 300
    @connection_timeout = 60
    @inactivity_timeout = 30
    @max_follow_redirects = 10
  end

  def run
    EM.run do
      EM.add_periodic_timer(@poll_period) do
        poll_projects
      end

      EM.add_periodic_timer(@tracker_poll_period) do
        poll_tracker
      end
    end
  end

  def run_once
    EM.run do
      poll_projects
    end

    EM.run do
      poll_tracker
    end
  end

  private

  def poll_tracker
    Project.tracker_updateable.find_each do |project|
      handler = ProjectTrackerWorkloadHandler.new(project)
      workload = find_or_create_workload(project, handler)

      workload.unfinished_job_descriptions.each do |job_id, description|
        request = create_tracker_request(project, description)
        add_workload_callbacks(project, workload, job_id, request, handler)
      end
    end
  end

  def poll_projects
    Project.updateable.find_each do |project|
      handler = ProjectWorkloadHandler.new(project)
      workload = find_or_create_workload(project, handler)

      workload.unfinished_job_descriptions.each do |job_id, description|
        request = create_ci_request(project, description)
        add_workload_callbacks(project, workload, job_id, request, handler) if request
      end
    end
  end

  def create_tracker_request(project, url)
    create_request(url, head: {'X-TrackerToken' => project.tracker_auth_token})
  end

  def create_ci_request(project, url)
    get_options = {}
    if project.auth_username.present?
      get_options[:head] = {'authorization' => [project.auth_username, project.auth_password]}
    end
    if project.accept_mime_types.present?
      headers = get_options[:head] || {}
      get_options[:head] = headers.merge("Accept" => project.accept_mime_types)
    end

    create_request(url, get_options)
  end

  def create_request(url, options = {})
    url = "http://#{url}" unless /\A\S+:\/\// === url
    begin
      connection = EM::HttpRequest.new url, connect_timeout: @connection_timeout, inactivity_timeout: @inactivity_timeout
      get_options = {redirects: @max_follow_redirects}.merge(options)
      connection.get get_options
    rescue Addressable::URI::InvalidURIError => e
      puts "ERROR parsing URL: \"#{url}\""
    end
  end

  def add_workload_callbacks(project, workload, job_id, request, handler)
    request.callback do |client|
      workload.store(job_id, client.response)

      if workload.complete?
        handler.workload_complete(workload)
        remove_workload(project)
      end
    end

    request.errback do |client|
      handler.workload_failed(workload, client.error)
      remove_workload(project)
    end
  end

  def find_or_create_workload(project, handler)
    unless @workloads.has_key? project
      workload = PollerWorkload.new
      @workloads[project] = workload
      handler.workload_created(workload)
    end

    @workloads[project]
  end

  def remove_workload(project)
    @workloads.delete(project)
  end

end
