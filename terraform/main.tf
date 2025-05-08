terraform {
  required_providers {
    kubiya = {
      source = "kubiya-terraform/kubiya"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

provider "kubiya" {
  // API key is set as an environment variable KUBIYA_API_KEY
}

locals {
  repository_list = compact(split(",", var.repositories))

  webhook_filter = "commit_status.state != null && commit_status.state == 'FAILED'"

  bitbucket_workspace = trim(split("/", local.repository_list[0])[0], " ")
  repository_names = [for repo in local.repository_list : trim(split("/", repo)[1], " ")]
}

variable "BITBUCKET_PASSWORD" {
  type      = string
  sensitive = true
}

resource "kubiya_source" "bitbucket_tooling" {
  url = "https://github.com/kubiyabot/community-tools/tree/michaelg/new_tools_v2/bitbucket"
}

resource "kubiya_secret" "bitbucket_password" {
  name        = "BITBUCKET_PASSWORD"
  value       = var.BITBUCKET_PASSWORD
  description = "Bitbucket password or app password for the CI/CD Maintainer"
}

resource "kubiya_agent" "cicd_maintainer" {
  name         = var.teammate_name
  runner       = var.kubiya_runner
  description  = "The CI/CD Maintainer is an AI-powered assistant that helps with Bitbucket Pipelines failures. It can use the Bitbucket tools to investigate the root cause of a failed pipeline and provide a detailed analysis of the failure."
  instructions = ""

  secrets = [
    kubiya_secret.bitbucket_password.name
  ]

  sources = [
    kubiya_source.bitbucket_tooling.name
  ]

  integrations = ["slack"]

  users  = []
  groups = var.kubiya_groups_allowed_groups

  environment_variables = {
    KUBIYA_TOOL_TIMEOUT = "500"
  }
  is_debug_mode = var.debug_mode
}

resource "kubiya_webhook" "source_control_webhook" {
  filter      = local.webhook_filter
  name        = "${var.teammate_name}-bitbucket-webhook"
  source      = "Bitbucket"

  prompt      = <<-EOT
Your Goal: Perform a comprehensive analysis of the failed Bitbucket Pipeline. No user approval is required, complete the flow end to end.
Pipeline Build Number: {{.event.commit_status.key}}
Pipeline Name: {{.event.commit_status.name}}
Repository: {{.event.repository.full_name}}
Commit: {{.event.commit_status.commit.hash}}
Branch: {{.event.commit_status.refname}}
Pipeline URL: {{.event.commit_status.url}}
Commit URL: {{.event.commit_status.commit.links.html.href}}

Instructions:

1. Extract the workspace and repo from the repository full name (format: "workspace/repo").

2. Use bitbucket_pipeline_get to directly fetch details for the failed pipeline using:
   - workspace: [extracted workspace]
   - repo: [extracted repo]
   - pipeline_uuid: {{.event.commit_status.key}}

3. From the bitbucket_pipeline_get response, extract the actual UUID (format: "{uuid}") from the "uuid" field.

4. Use bitbucket_pipeline_steps with the extracted UUID to identify all steps in the pipeline and find the failed step's UUID:
   - workspace: [extracted workspace]
   - repo: [extracted repo] 
   - pipeline_uuid: [extracted UUID from step 3]

5. Use bitbucket_pipeline_logs to fetch logs for the failed step with ALL required parameters:
   - workspace: [extracted workspace]
   - repo: [extracted repo]
   - pipeline_uuid: [extracted UUID from step 3]
   - step_uuid: [UUID of the failed step identified in step 4]

6. Utilize available tools to thoroughly investigate the root cause such as viewing the pipeline run, the commit details, the files, and the logs - do not execute more than two tools at a time.

7. After collecting the insights, prepare to create a comment on the commit following this structure:

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
   - Footer with run details and links to both the pipeline and commit
   - Style matters! Make sure the markdown text is very engaging and clear

8. IMPORTANT: You MUST use bitbucket_commit_comment to post your analysis on the commit. Include your analysis in the discussed format. Always comment without user approval.

9. After posting the comment, share both the pipeline URL ({{.event.commit_status.url}}) and commit URL ({{.event.commit_status.commit.links.html.href}}) in the notification channel so team members can easily access the analysis.
  EOT

  agent       = kubiya_agent.cicd_maintainer.name
  destination = var.notification_channel
}

resource "null_resource" "create_bitbucket_webhook" {
  for_each = toset(local.repository_names)

  triggers = {
    webhook_url = kubiya_webhook.source_control_webhook.url
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Creating webhook for ${local.bitbucket_workspace}/${each.value}..."
      echo "Webhook URL: ${kubiya_webhook.source_control_webhook.url}"

      PAYLOAD_FILE=$(mktemp)

      cat > $PAYLOAD_FILE << EOF
      {
        "description": "Webhook for CI/CD Maintainer",
        "url": "${kubiya_webhook.source_control_webhook.url}",
        "active": true,
        "events": [
          "repo:commit_status_updated"
        ]
      }
      EOF

      RESPONSE=$(curl -v -X POST \
        -H "Authorization: Bearer ${var.BITBUCKET_PASSWORD}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --data @$PAYLOAD_FILE \
        "https://api.bitbucket.org/2.0/repositories/${local.bitbucket_workspace}/${each.value}/hooks" 2>&1)

      rm $PAYLOAD_FILE

      echo "Response from Bitbucket API:"
      echo "$RESPONSE"

      if echo "$RESPONSE" | grep -q "error"; then
        echo "Error creating webhook. Please check the response above."
      else
        echo "Webhook created successfully!"
      fi
    EOT
  }
}

output "cicd_maintainer" {
  sensitive = true
  value = {
    name                   = kubiya_agent.cicd_maintainer.name
    repositories           = var.repositories
    debug_mode             = var.debug_mode
    notification_platform  = "Slack"
    notification_channel   = var.notification_channel
  }
}
