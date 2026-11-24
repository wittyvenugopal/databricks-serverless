-- Serverless job cost and governance checks on system tables (run in the SQL editor).
-- Needs SELECT on system.billing and system.lakeflow. Usage rows arrive a few hours after a run.
-- list_cost = DBUs x list price (no discounts).

-- 1. Cost per day, by job tags (job `tags`, bundle `presets.tags` and policy tags all land in custom_tags)
select u.usage_date,
       u.custom_tags['project']                 as project,
       u.custom_tags['cost_centre']             as cost_centre,
       u.usage_metadata.job_id                  as job_id,
       u.product_features.performance_target    as performance_target,
       round(sum(u.usage_quantity), 3)          as dbus,
       round(sum(u.usage_quantity * p.pricing.effective_list.default), 3) as list_cost
from system.billing.usage u
join system.billing.list_prices p
  on u.sku_name = p.sku_name and u.cloud = p.cloud
 and u.usage_start_time >= p.price_start_time
 and (p.price_end_time is null or u.usage_start_time < p.price_end_time)
where u.billing_origin_product = 'JOBS' and u.product_features.is_serverless
  and u.usage_date >= current_date - 30
group by all
order by u.usage_date desc, list_cost desc;

-- 2. Serverless jobs with no cost_centre tag (who to chase), with the job name and run-as
with jobs as (
  select workspace_id, job_id, name, run_as
  from system.lakeflow.jobs
  qualify row_number() over (partition by workspace_id, job_id order by change_time desc) = 1
)
select u.workspace_id, u.usage_metadata.job_id as job_id, j.name, j.run_as,
       round(sum(u.usage_quantity), 2) as dbus
from system.billing.usage u
left join jobs j on j.workspace_id = u.workspace_id and j.job_id = u.usage_metadata.job_id
where u.billing_origin_product = 'JOBS' and u.product_features.is_serverless
  and u.usage_date >= current_date - 30
  and u.custom_tags['cost_centre'] is null
group by all
order by dbus desc
limit 50;

-- 3. Performance mode split (STANDARD uses fewer DBUs; PERFORMANCE_OPTIMIZED starts fast)
select u.workspace_id, u.product_features.performance_target as performance_target,
       count(distinct u.usage_metadata.job_id) as jobs, round(sum(u.usage_quantity), 1) as dbus
from system.billing.usage u
where u.billing_origin_product = 'JOBS' and u.product_features.is_serverless
  and u.usage_date >= current_date - 30
group by all
order by dbus desc;

-- 4. Usage policy coverage: share of serverless DBUs that carry a usage/budget policy
select u.workspace_id,
       round(coalesce(sum(case when coalesce(u.usage_metadata.usage_policy_id, u.usage_metadata.budget_policy_id) is not null
                      then u.usage_quantity end), 0) / sum(u.usage_quantity) * 100, 1) as pct_with_policy,
       round(sum(u.usage_quantity), 1) as dbus
from system.billing.usage u
where u.product_features.is_serverless and u.usage_date >= current_date - 30
group by all
order by dbus desc;

-- 5. Cost per run of one job (e.g. compare a STANDARD and a PERFORMANCE_OPTIMIZED run)
select u.usage_metadata.job_run_id as run_id, u.product_features.performance_target as performance_target,
       round(sum(u.usage_quantity), 4) as dbus
from system.billing.usage u
where u.usage_metadata.job_id = :job_id
group by all
order by run_id;

-- 6. Budget check for an alert: month-to-date list cost per cost_centre over :budget
select u.custom_tags['cost_centre'] as cost_centre,
       round(sum(u.usage_quantity * p.pricing.effective_list.default), 2) as mtd_list_cost
from system.billing.usage u
join system.billing.list_prices p
  on u.sku_name = p.sku_name and u.cloud = p.cloud
 and u.usage_start_time >= p.price_start_time
 and (p.price_end_time is null or u.usage_start_time < p.price_end_time)
where u.product_features.is_serverless and u.usage_date >= date_trunc('month', current_date)
group by all
having mtd_list_cost > :budget;
