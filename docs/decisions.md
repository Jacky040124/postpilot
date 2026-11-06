# Design decisions

Short records of the choices that shaped this project, so the reasoning is not lost.

## ADR-001: ECS Fargate instead of EKS

**Context:** Two small stateless services (api, worker). One person maintains it.

**Decision:** Run them on ECS Fargate.

**Why:** No nodes to patch or scale, no cluster add-ons to upgrade, no control-plane fee
(EKS charges about $73/month per cluster before any workload). ECS gives us what we need out
of the box: rolling deploys, a deployment circuit breaker with automatic rollback, ALB
integration, and per-task IAM roles.

**Trade-off:** Less portable than Kubernetes and fewer ecosystem tools (Helm, operators). If
the platform grew to many services and teams, EKS could be worth its overhead.

## ADR-002: GitHub OIDC instead of stored AWS keys

**Decision:** GitHub Actions gets AWS credentials by exchanging its OIDC token for an IAM
role (`aws-actions/configure-aws-credentials`).

**Why:** There is no long-lived secret to leak or rotate. Credentials last an hour at most.
The role's trust policy decides *which* workflows can use it: the deploy role only trusts
jobs running in the `dev` or `prod` GitHub environment, so a pull request cannot deploy, and
prod jobs only get a token after a required reviewer approves.

**Trade-off:** Needs a one-time bootstrap (OIDC provider + roles) in each AWS account.

## ADR-003: Two IAM roles for CI (plan and deploy)

**Decision:** `postpilot-github-plan` is read-only and can be used by pull requests.
`postpilot-github-deploy` can push images and update ECS services, and only from the
`dev`/`prod` environments.

**Why:** Pull requests run code that has not been reviewed yet. Giving them only read access
limits the damage a malicious or buggy PR can do.

## ADR-004: CI deploys the image; Terraform owns everything else

**Decision:** The ECS services have `lifecycle { ignore_changes = [task_definition] }`. The
deploy workflow registers a new task definition revision with the new image and updates the
services.

**Why:** Deploying a new version is fast and does not need Terraform state or broad
permissions in CI. Infrastructure changes still go through Terraform and code review.

**Trade-off:** Terraform state does not show which image is running. `aws ecs describe-services`
does. Task definition changes made in Terraform (e.g. new env vars) are picked up on the next
deploy, which copies the latest revision.

## ADR-005: RDS manages the database password

**Decision:** `manage_master_user_password = true`. RDS generates the password and stores it
in Secrets Manager. ECS injects it into the containers at start (`DB_PASSWORD`).

**Why:** The password never appears in Terraform code, plans, or state, and RDS can rotate it.
The alternative (`random_password` + our own secret) writes the password into the state file.

**Trade-off:** RDS rotates this secret every 7 days by default, and ECS only injects secrets
when a task starts. Existing connections keep working, but a long-running task that opens a
new connection after a rotation would use the old password. Not solved yet; options are to
read the secret from Secrets Manager when the connection pool connects (needs a task role
permission) or to force a new deployment after each rotation via an EventBridge rule.

## ADR-006: Postgres as the queue (no SQS)

**Decision:** The worker polls the `posts` table and claims rows with
`SELECT ... FOR UPDATE SKIP LOCKED`.

**Why:** Posts are already in Postgres, so there is no second system to keep in sync and no
"saved in DB but message lost" case. `SKIP LOCKED` makes it safe to run several workers.
At this scale (posts per minute, not per millisecond) polling is cheap.

**Trade-off:** Polling adds up to `POLL_INTERVAL_SECONDS` of delay and a small constant DB
load. At much higher volume SQS or EventBridge Scheduler would fit better.

## ADR-007: One ECR repository per environment

**Decision:** dev and prod each have their own repository. A `v*` tag builds the image again
from the tagged commit and pushes it to the prod repository.

**Why:** Keeps environments fully separate and the IAM simple.

**Trade-off:** Prod does not run the exact bytes tested in dev. Base image updates between the
two builds could change them. The better version is "build once, promote": copy the image by
digest from dev to prod, or use one shared repository. That is the next improvement.

## ADR-008: Liveness vs readiness

**Decision:** `/healthz` only says the process is running. `/readyz` also checks the database.
The container health check uses `/healthz`; the ALB uses `/readyz`.

**Why:** If the database has a blip, we want the ALB to stop sending traffic, but we do not
want ECS to kill and restart every task, which would make recovery slower.

## ADR-009: Different sizes per environment, same modules

**Decision:** `infra/envs/dev` and `infra/envs/prod` call the same modules with different
inputs. Sizes are listed in a `local.size` block at the top of each `main.tf`.

**Why:** What differs between environments is visible in one place, and a change to a module
is tested in dev before prod. Prod gets the expensive resilience (NAT per AZ, Multi-AZ RDS,
two of each task, deletion protection); dev stays cheap.
