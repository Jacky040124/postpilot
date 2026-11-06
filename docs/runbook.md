# PostPilot runbook

Every CloudWatch alarm links to a section here. Each section says what the alarm
means, what to check, and how to fix or roll back. Replace `<env>` with `dev` or
`prod`; names follow `postpilot-<env>-...`.

## First five minutes (any alarm)

1. **Did something just change?** Check the latest Deploy run in GitHub Actions and the
   ECS service events:
   ```bash
   aws ecs describe-services --cluster postpilot-<env> --services postpilot-<env>-api postpilot-<env>-worker \
     --query 'services[].{name:serviceName,deployments:deployments[].{status:status,rollout:rolloutState,taskDef:taskDefinition,running:runningCount}}'
   ```
   If the alarm started right after a deploy, roll back first and debug after (see below).
2. **Look at the logs.** In CloudWatch Logs Insights, select `/ecs/postpilot-<env>/api` and
   `/ecs/postpilot-<env>/worker`:
   ```
   fields @timestamp, level, message, path, status, error, post_id
   | filter level in ["WARNING", "ERROR"]
   | sort @timestamp desc
   | limit 100
   ```
3. **Check the database.** RDS console -> `postpilot-<env>` -> CPU, connections, free storage.

## Rolling back

ECS keeps every task definition revision. Rolling back means pointing the service at the
previous one.

- **Automatic:** a deploy whose new tasks fail health checks is stopped by the deployment
  circuit breaker, which returns the service to the last revision that worked. The Deploy
  workflow then fails. Nothing to do except fix the bug.
- **Manual** (the deploy "succeeded" but the new version misbehaves):
  ```bash
  # find the previous revision
  aws ecs list-task-definitions --family-prefix postpilot-<env>-api --sort DESC --max-items 3
  # point the service back at it (same for -worker)
  aws ecs update-service --cluster postpilot-<env> --service postpilot-<env>-api \
    --task-definition postpilot-<env>-api:<previous-revision>
  aws ecs wait services-stable --cluster postpilot-<env> --services postpilot-<env>-api
  ```
  Then `git revert` the bad commit so the next deploy does not bring it back.
- **Infrastructure change** (a `terraform apply` broke something): revert the commit and
  `terraform apply` again. State is versioned in S3 if it ever needs restoring.

## alb-5xx-rate

**Means:** more than 5% (dev) / 2% (prod) of requests returned a 5xx for 3 of the last 5 minutes.

**Check:**
- Is it the app (`HTTPCode_Target_5XX_Count`) or the ALB itself (`HTTPCode_ELB_5XX_Count`)?
  ELB 5xx (502/503) usually means there are no healthy tasks. Go to
  [unhealthy-targets](#unhealthy-targets).
- App 5xx: search the api logs for `"status": 500` and for tracebacks (`exc_info`).
- Database trouble shows up as `readiness_failed` log lines and failing `/readyz`.

**Fix:** if it started after a deploy, roll back. If the DB is the cause, see RDS metrics
(connections maxed, storage full, failover in progress on Multi-AZ).

## alb-p95-latency

**Means:** the slowest 5% of requests took over 1s (dev) / 0.5s (prod).

**Check:**
- API CPU (the `api-cpu-high` alarm, or the ECS service metrics). If CPU is high, autoscaling
  should already be adding tasks; check it has not hit `api_max_count`.
- RDS CPU and read/write latency. `GET /posts` is the heaviest query.
- In logs, sort by `duration_ms` to find the slow route:
  ```
  fields @timestamp, path, duration_ms | sort duration_ms desc | limit 20
  ```

**Fix:** raise `api_max_count` or task size in `infra/envs/<env>/main.tf`, or the DB instance
class. Roll back if a deploy caused it.

## unhealthy-targets

**Means:** the ALB health check (`GET /readyz`) is failing on at least one API task.

**Check:**
- `/readyz` fails when the DB is unreachable. Check RDS status and the DB security group.
- ECS service events show tasks being stopped and why (`Essential container exited`,
  `failed container health checks`, image pull errors).
- Stopped task reason:
  ```bash
  aws ecs list-tasks --cluster postpilot-<env> --service-name postpilot-<env>-api --desired-status STOPPED
  aws ecs describe-tasks --cluster postpilot-<env> --tasks <task-arn> --query 'tasks[].stoppedReason'
  ```

**Fix:** during a deploy the circuit breaker handles this. Outside a deploy it is almost
always the database or a secret that changed (e.g. the RDS-managed password was rotated and
tasks need a restart: `aws ecs update-service ... --force-new-deployment`).

## ecs-cpu-high

**Means:** a service averaged over 80% CPU for 15 minutes.

**Check:**
- **api:** is traffic up (ALB `RequestCount`)? Autoscaling targets 60% CPU, so a sustained
  80% means it is at its max task count.
- **worker:** a large backlog (`queue_backlog`, or many posts due at once) keeps it busy. It
  is single-threaded per task, so more tasks = more throughput.

**Fix:** api: raise `api_max_count` or `api_cpu`. worker: raise `worker_count`. Running more
workers is safe because of `FOR UPDATE SKIP LOCKED`.

## publish-failures

**Means:** the worker logged `publish_failed` 5+ (dev) / 3+ (prod) times in 5 minutes.
Each failure is retried with backoff; after `MAX_ATTEMPTS` the post is marked `failed`.

**Check:**
```
fields @timestamp, post_id, attempt, final, error
| filter message = "publish_failed"
| stats count() by error
```
- `webhook returned 404` / `401`: the webhook URL is wrong or was revoked.
- `webhook returned 429`: rate limited by Discord/Slack. Lower `BATCH_SIZE` or raise
  `POLL_INTERVAL_SECONDS`.
- `webhook returned 5xx` or `ConnectError` / `ReadTimeout`: the chat service is having
  problems, or outbound traffic is blocked (NAT gateway, security group egress).

**Fix:** to replace the webhook URL:
```bash
aws ssm put-parameter --name /postpilot-<env>/webhook-url --type SecureString --overwrite --value 'https://...'
aws ecs update-service --cluster postpilot-<env> --service postpilot-<env>-worker --force-new-deployment
```
Secrets are read when a task starts, so the restart is needed. Posts already marked `failed`
are not retried automatically; list them with `GET /posts?status=failed`.
