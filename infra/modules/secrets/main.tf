# Application secrets that are not owned by another AWS service.
#
# The DB password is NOT here on purpose: RDS generates it and stores it in
# Secrets Manager itself (manage_master_user_password in the rds module), so the
# password never appears in Terraform state. See docs/decisions.md (ADR-005).

resource "aws_ssm_parameter" "webhook_url" {
  name        = "/${var.name}/webhook-url"
  description = "Discord/Slack incoming webhook URL used by the worker"
  type        = "SecureString"

  # Placeholder only. Set the real value out of band so it never lives in git or state:
  #   aws ssm put-parameter --name /<name>/webhook-url --type SecureString --overwrite --value 'https://...'
  value = "https://example.invalid/replace-me"

  lifecycle {
    ignore_changes = [value]
  }
}
