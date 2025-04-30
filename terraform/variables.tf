# Required Core Configuration
variable "teammate_name" {
  description = "Name of your CI/CD maintainer teammate (e.g., 'cicd-crew' or 'pipeline-guardian'). Used to identify the teammate in logs, notifications, and webhooks."
  type        = string
  default     = "cicd-crew"
}

variable "repositories" {
  description = "Comma-separated list of repositories to monitor in 'workspace/repo' format (e.g., 'mycompany/backend-api,mycompany/frontend-app'). Ensure you have appropriate permissions."
  type        = string
}

variable "notification_channel" {
  description = "The Slack channel to send pipeline notifications to (e.g., '#general')."
  type        = string
  default     = "#ci-cd-maintainers-crew"
}

# Access Control
variable "kubiya_groups_allowed_groups" {
  description = "Groups allowed to interact with the teammate (e.g., ['Admin', 'DevOps'])."
  type        = list(string)
  default     = ["Admin"]
}

# Kubiya Runner Configuration
variable "kubiya_runner" {
  description = "Runner to use for the teammate. Change only if using custom runners."
  type        = string
}

# Webhook Filter Configuration
variable "monitor_pr_workflow_runs" {
  description = "Listen for pipeline runs that are associated with pull requests"
  type        = bool
  default     = true
}

variable "monitor_push_workflow_runs" {
  description = "Listen for pipeline runs triggered by push events"
  type        = bool
  default     = true
}

variable "monitor_failed_runs_only" {
  description = "Only monitor failed pipeline runs (if false, will monitor all conclusions)"
  type        = bool
  default     = true
}

variable "debug_mode" {
  description = "Debug mode allows you to see more detailed information and outputs during runtime (shows all outputs and logs when conversing with the teammate)"
  type        = bool
  default     = false
}

variable "enable_branch_filter" {
  description = "Whether to enable branch filtering for webhook events"
  type        = bool
  default     = false
}

variable "head_branch_filter" {
  description = "The branch name to filter webhook events on. Only used when enable_branch_filter is true."
  type        = string
  default     = "main"
  validation {
    condition     = var.head_branch_filter == null || can(regex("^[a-zA-Z0-9-_.]+$", var.head_branch_filter))
    error_message = "head_branch_filter must be either null or a valid branch name containing only alphanumeric characters, hyphens, underscores, and dots."
  }
}