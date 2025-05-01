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
  url = "https://github.com/kubiyabot/community-tools/tree/main/bitbucket"
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
          "build:status:updated"
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
