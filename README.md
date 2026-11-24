# Governing Databricks serverless jobs – a hands-on lab

What can you actually control about serverless jobs: cost attribution, who may use it, how much a run may cost,
and how you find out? This repo is a small Databricks Asset Bundle that tries each control, plus the results
measured on **Databricks Free Edition** (November 2026).

## Result in one line

**Nothing hard-stops serverless job spend.** The levers are *attribution* (job tags, usage policies), *limits per
run* (timeouts, concurrency) and *alerts* (job health rules, SQL budget alerts, account budgets).
The cheapest single change is `performance_target: STANDARD`: **~68% fewer DBUs** on the same job.

## What's in the repo

| Path | What |
|---|---|
| `databricks.yml` | bundle: variables (`cost_centre`, `budget_policy_id`, `performance_target`, `monthly_budget`), target `dev` with `presets.tags` |
| `resources/serverless_governed.job.yml` | serverless job with every job-level control, each one commented |
| `resources/serverless_limits_test.job.yml` | same work with tight limits (90 s timeout, 20 s health rule, 1 concurrent run) |
| `resources/serverless_budget.alert.yml` | SQL alert: month-to-date serverless cost per `cost_centre` over budget → email |
| `src/busy_work.py` | a little Spark work (+ optional sleep) so runs use compute |
| `sql/serverless_usage.sql` | cost per tag, untagged jobs, performance-mode split, policy coverage, cost per run, budget check |
| `docs/screenshots/` | evidence for the findings below |

## Run it

Needs the Databricks CLI with a profile, and a SQL warehouse named "Serverless Starter Warehouse"
(Free Edition has one; otherwise `--var warehouse_id=<id>`).

```
databricks bundle deploy -p <profile>
databricks bundle run serverless_governed -p <profile>
databricks bundle run serverless_limits_test -p <profile> --params sleep_seconds=30    # health warning
databricks bundle run serverless_limits_test -p <profile> --params sleep_seconds=120   # timeout
# with a usage policy (create it first, see below):
databricks bundle deploy -p <profile> --var budget_policy_id=<policy id>
```

Billing rows (`system.billing.usage`) arrive a few hours after a run; then use `sql/serverless_usage.sql`.

## The controls

| Control | Who sets it | Where | What it does |
|---|---|---|---|
| Job `tags` | job owner | `tags:` on the job | copied to `system.billing.usage.custom_tags` → cost per project / cost centre |
| Bundle `presets.tags` | repo | target `presets: tags:` | same tags on every job of a target |
| **Usage policy** (formerly budget policy) | workspace admin creates it; users get the *User* role | Settings → Compute → Serverless usage policies; job field `budget_policy_id` / `usage_policy_id` | adds the policy's tags to usage. Tags only – **no spend cap** |
| Performance mode | job owner | `performance_target: STANDARD` / `PERFORMANCE_OPTIMIZED` (or per run in `run-now`) | STANDARD = fewer DBUs, starts in minutes |
| Timeout, concurrency, queue | job owner | `timeout_seconds` (job and task), `max_concurrent_runs`, `queue` | stops runaway and duplicate runs |
| Health alert | job owner | `health.rules` (`RUN_DURATION_SECONDS`) + `on_duration_warning_threshold_exceeded` | email when a run is slow, before the timeout |
| Job permissions | job owner | `permissions:` | who can see / run / edit |
| Entitlements | workspace admin | Settings → Identity and access → user → Entitlements | *Workspace access* is needed to create and run jobs at all |
| Budget alert | anyone with system-table access | `resources/serverless_budget.alert.yml` | email when month-to-date cost per `cost_centre` passes a threshold |
| Account budgets | account admin | Account console → Usage → Budgets | monthly thresholds by workspace / tag; alerts only for serverless jobs |
| Serverless rate limit (Beta) | workspace admin | Previews → "Serverless Compute Rate Limit" | caps DBU/hour per workload – **not offered on Free Edition** |

## Findings

### 1. STANDARD mode: ~68% fewer DBUs, minutes to start

Same job, two runs ([screenshot](docs/screenshots/09-billing-performance-mode-and-policy.png)):

| Mode | Start-up | Total | DBUs | List cost |
|---|---|---|---|---|
| PERFORMANCE_OPTIMIZED | 2 s | 20 s | 0.2659 | $0.0931 |
| STANDARD | 155 s | 180 s | 0.0852 | $0.0298 |

The start-up wait is not billed. Jobs created in the UI default to PERFORMANCE_OPTIMIZED – set STANDARD on every
batch job that isn't time-critical.

### 2. Job tags and policy tags both reach billing – job tags win on the same key

| Job | Policy | `custom_tags` in billing |
|---|---|---|
| bundle job, tags `project`, `cost_centre=data-platform`, ... | none | the job's tags |
| bundle job, same tags | usage policy (`cost_centre=finance`, `project=policy-test`) | **the job's tags** – policy values lost on the same keys |
| UI job, no tags | same usage policy | `cost_centre=finance`, `project=policy-test` |

So the policy is the *default* attribution and job tags *override* it. Use different keys if you need both.

### 3. A user's only policy is applied automatically

| User | Policy role | Their new job |
|---|---|---|
| A | *User* on the policy ([grant](docs/screenshots/02-grant-policy-user-role.png)) | policy applied without choosing it ([screenshot](docs/screenshots/03-policy-applied-automatically.png)) |
| B | none | no policy, no tags – the cost can't be attributed ([screenshot](docs/screenshots/07-job-without-policy-no-tags.png)) |

Our bundle job without a `budget_policy_id` field also got the policy (the deploying user had exactly one).
With several policies a user has to pick; existing jobs are not updated when access is granted.
**To make attribution complete, grant a policy's User role to a group** (e.g. `users`), not to individuals.

### 4. Entitlements are the first gate

A user with only *Consumer access* ([screenshot](docs/screenshots/04-consumer-entitlement-only.png)) can view jobs
shared with them, but creating one fails with "no access to Databricks Workspace"
([screenshot](docs/screenshots/05-consumer-cannot-create-job.png)). With *Workspace access* they can create and run
serverless jobs.

### 5. Jobs are private by default

A non-admin sees only jobs they own or were granted. Our job grants `CAN_VIEW` to `users`, so it was the only
bundle job they could see ([screenshot](docs/screenshots/06-non-admin-sees-only-shared-job.png)) – and with
`CAN_VIEW` they cannot run it.

### 6. Limits and alerts work as configured

| Test | Result |
|---|---|
| two runs at once, `max_concurrent_runs: 1`, queue on | second run `QUEUED` 67 s, started when the first ended |
| 90 s timeout, run sleeping 120 s | `TIMEDOUT` – still billed up to the timeout |
| 20 s health rule | duration-warning emails, plus the failure email for the timed-out run ([screenshot](docs/screenshots/08-duration-and-failure-emails.png)) |
| SQL budget alert, budget 50 USD | fired: `MAX(mtd_list_cost) 86.12 > 50` ([screenshot](docs/screenshots/10-budget-alert-email.png)) |

### Creating a usage policy

Settings → Compute → Serverless usage policies → Create ([screenshot](docs/screenshots/01-create-usage-policy.png)):
name, optional workspaces, fixed tags. Then Permissions → Grant access → *Serverless usage policy: User*.
There is no public workspace API for this; it's UI (or account-level API) only.

## Gotchas

- `budget_policy_id` and `usage_policy_id` on a job point to the same object (both `effective_*` fields show the same id).
- Bundle **development mode deploys alerts PAUSED**, even with `schedule.pause_status: UNPAUSED`.
  Resume in the UI or with `databricks alerts-v2 update-alert <id> schedule --json '{"schedule": {..., "pause_status": "UNPAUSED"}}'`.
- Billing is a few hours behind; `select max(usage_end_time) from system.billing.usage` shows how far.
- Not available on Free Edition: serverless rate limits / serverless compute policies, account budgets.

Tested 2026-11-23 on Databricks Free Edition, Databricks CLI v0.290 (`DATABRICKS_BUNDLE_ENGINE=direct`).
