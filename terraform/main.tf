terraform {
  required_providers {
    kubiya = {
      source = "kubiya-terraform/kubiya"
    }
    bitbucket = {
      source  = "DrFaust92/bitbucket"
      version = "2.30.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "kubiya" {
  // API key is set as an environment variable KUBIYA_API_KEY
}

locals {
  # Repository list handling
  repository_list = compact(split(",", var.repositories))

  # Event configurations
  bitbucket_events = ["repo:push", "pullrequest:created", "pullrequest:updated", "pullrequest:rejected", "pullrequest:fulfilled"]

  # Construct webhook filter based on variables
  webhook_filter_conditions = concat(
    # Base condition for pipeline runs
    ["pipeline.state != null"],

    # Failed runs condition
    var.monitor_failed_runs_only ? ["pipeline.state == 'FAILED'"] : [],

    # Event type conditions
    [format("(%s)",
      join(" || ",
        concat(
          var.monitor_pr_workflow_runs ? ["event.pullrequest != null"] : [],
          var.monitor_push_workflow_runs ? ["event.push != null"] : []
        )
      )
    )],

    # Branch filtering if enabled and specified
    var.enable_branch_filter && var.head_branch_filter != null ? ["event.push.changes[0].new.name == '${var.head_branch_filter}' || event.pullrequest.source.branch.name == '${var.head_branch_filter}'"] : []
  )

  webhook_filter = join(" && ", local.webhook_filter_conditions)

  # Bitbucket workspace handling
  bitbucket_workspace = trim(split("/", local.repository_list[0])[0], " ")
}

variable "BITBUCKET_USERNAME" {
  type      = string
  sensitive = true
}

variable "BITBUCKET_PASSWORD" {
  type      = string
  sensitive = true
}

# Configure providers
provider "bitbucket" {
  username = var.BITBUCKET_USERNAME
  password = var.BITBUCKET_PASSWORD
}

# Bitbucket Tooling - Allows the CI/CD Maintainer to use Bitbucket tools
resource "kubiya_source" "bitbucket_tooling" {
  url = "https://github.com/kubiyabot/community-tools/tree/main/bitbucket"
}

# Create secrets using provider
resource "kubiya_secret" "bitbucket_username" {
  name        = "BITBUCKET_USERNAME"
  value       = var.BITBUCKET_USERNAME
  description = "Bitbucket username for the CI/CD Maintainer"
}

resource "kubiya_secret" "bitbucket_password" {
  name        = "BITBUCKET_PASSWORD"
  value       = var.BITBUCKET_PASSWORD
  description = "Bitbucket password or app password for the CI/CD Maintainer"
}

# Configure the CI/CD Maintainer agent
resource "kubiya_agent" "cicd_maintainer" {
  name         = var.teammate_name
  runner       = var.kubiya_runner
  description  = "The CI/CD Maintainer is an AI-powered assistant that helps with Bitbucket Pipelines failures. It can use the Bitbucket tools to investigate the root cause of a failed pipeline and provide a detailed analysis of the failure."
  instructions = ""
  
  secrets      = [
    kubiya_secret.bitbucket_username.name,
    kubiya_secret.bitbucket_password.name
  ]
  
  sources = [
    kubiya_source.bitbucket_tooling.name,
  ]

  # Dynamic integrations based on configuration
  integrations = ["slack"]

  users  = []
  groups = var.kubiya_groups_allowed_groups

  environment_variables = {
    KUBIYA_TOOL_TIMEOUT = "500"
  }
  is_debug_mode = var.debug_mode
}

# Unified webhook configuration for Slack
resource "kubiya_webhook" "source_control_webhook" {
  filter      = local.webhook_filter
  name        = "${var.teammate_name}-bitbucket-webhook"
  source      = "Bitbucket"
  
  prompt      = <<-EOT
Your Goal: Perform a comprehensive analysis of the failed Bitbucket Pipeline. No user approval is required, complete the flow end to end.
Pipeline ID: {{.event.pipeline.uuid}}
PR Number: {{if .event.pullrequest}}{{.event.pullrequest.id}}{{else}}N/A{{end}}
Repository: {{.event.repository.full_name}}

Instructions:

1. Use bitbucket_pipeline_logs to fetch failed logs for Pipeline ID {{.event.pipeline.uuid}}. Wait until this step finishes.

2. Utilize available tools to thoroughly investigate the root cause such as viewing the pipeline run, the PR, the files, and the logs - do not execute more than two tools at a time.

3. After collecting the insights, prepare to create a comment on the pull request following this structure:

a. Highlights key information first:
   - What failed
   - Why it failed 
   - How to fix it

b. Add a mermaid diagram showing:
   - Pipeline steps
   - Failed step highlighted
   - Error location

c. Format using:
   - Clear markdown headers
   - Emojis for quick scanning
   - Error logs in collapsible sections
   - Footer with run details
   - Style matters! Make sure the markdown text is very engaging and clear

4. Always use bitbucket_pr_comment to post your analysis on PR #{{if .event.pullrequest}}{{.event.pullrequest.id}}{{else}}N/A{{end}}. Include your analysis in the discussed format. Always comment on the PR without user approval.

  EOT
  agent       = kubiya_agent.cicd_maintainer.name
  destination = var.notification_channel
}

# Bitbucket repository webhooks
resource "bitbucket_webhook" "webhook" {
  for_each = length(local.repository_list) > 0 ? toset(local.repository_list) : []

  workspace = local.bitbucket_workspace
  repository = try(
    trim(split("/", each.value)[1], " "),
    # Fallback if repository name can't be parsed
    each.value
  )
  
  url          = kubiya_webhook.source_control_webhook.url
  description  = "Webhook for CI/CD Maintainer"
  active       = true
  events       = local.bitbucket_events
}

# Output the teammate details
output "cicd_maintainer" {
  sensitive = true
  value = {
    name                               = kubiya_agent.cicd_maintainer.name
    repositories                       = var.repositories
    debug_mode                         = var.debug_mode
    monitor_pr_workflow_runs           = var.monitor_pr_workflow_runs
    monitor_push_workflow_runs         = var.monitor_push_workflow_runs
    monitor_failed_runs_only           = var.monitor_failed_runs_only
    notification_platform              = "Slack"
    notification_channel               = var.notification_channel
  }
}
