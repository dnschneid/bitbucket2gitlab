#!/usr/bin/env ruby

require 'gitlab'
require 'json'
require 'recursive-open-struct'
require 'logger'
require 'pry'

clients          = {}
private_tokens   = {'bitbucket_username' => 'gitlab_private_token',
                    'bitbucket_collaborator2' => 'gitlab_collaborator_private_token'}
issues_json_file = '/tmp/db-1.0.json'
api_url          = 'https://gitlab.example.net/api/v3'
project_name     = 'repo/name'
project          = nil

MAP_ISSUE = {
    status:     :state,
    created_on: :created_at,
    updated_on: :updated_at,
    content:    :description,
}

class BitBucket2Gitlab

  def self.milestones
    @@milestones ||= []
  end

  def self.users
    @@users ||= {}
  end

  def self.clients
    @@clients ||= {}
  end

  def self.logger
    @@logger ||= Logger.new(STDOUT)
  end
end

def gitlab(bitbucket_username = nil)
  return BitBucket2Gitlab.clients.first[1] unless bitbucket_username
  return BitBucket2Gitlab.clients[bitbucket_username]
end

def logger
  BitBucket2Gitlab.logger
end

def gitlab_user_id(bitbucket_username)
  gitlab(bitbucket_username).user.id
end

def gitlab_milestone_id(bitbucket_name)
  return nil if BitBucket2Gitlab.milestones.empty?
  BitBucket2Gitlab.milestones.select { |m| m.title == bitbucket_name }.first.id rescue nil
end

def translate_data(data, map)

  translated = {}

  map.each do |k, v|
    translated[v] = data[k]
  end

  translated

end

private_tokens.each do |bitbucket_username, gitlab_token|
  BitBucket2Gitlab.clients[bitbucket_username] = Gitlab.client(endpoint: api_url, private_token: gitlab_token)
end

data = RecursiveOpenStruct.new(JSON.parse(IO.read(issues_json_file)), :recurse_over_arrays => true)

gitlab.projects.each do |p|
  if p.path_with_namespace == project_name
    project = p
    break
  end
end

abort "no project found" unless project

# create milestones
gitlab.milestones(project.id).each do |m|
  BitBucket2Gitlab.milestones.push(m)
end

logger.info "found #{data.milestones.count} milestones to migrate"


data.milestones.each do |bitbucket_milestone|
  if gitlab_milestone_id(bitbucket_milestone.name)
    logger.debug "skipping existing milestone '#{bitbucket_milestone.name}'"
  else
    gitlab.create_milestone(project.id, bitbucket_milestone.name)
  end
end

logger.info "found #{data.issues.count} issues to migrate"

data.issues.each do |bitbucket_issue|

  # TODO: detect duplicates

  issue_data = translate_data(bitbucket_issue, MAP_ISSUE)

  issue_data[:assignee_id]  = gitlab_user_id(bitbucket_issue.assignee)
  issue_data[:milestone_id] = gitlab_milestone_id(bitbucket_issue.milestone)

  issue = gitlab(bitbucket_issue.reporter).create_issue(project.id, bitbucket_issue.title, issue_data)

  bitbucket_comments = data['comments'].select { |c| c['issue'] == issue.id }.sort { |a, b| a['created_on'] <=> b['created_on'] } rescue []

  bitbucket_comments.each do |bitbucket_comment|

    content = bitbucket_comment.content
    content = '-' if content.nil?
    comment = gitlab(bitbucket_comment['user']).create_issue_note(project.id, issue.id, content)

  end

  gitlab(bitbucket_issue.reporter).close_issue(project.id, issue.id) if bitbucket_issue.status == 'resolved'

end

