# Migration programme backlog

5 epics, 54 stories and tasks.

## Discovery and assessment

Inventory the estate, agree a strategy and owner per workload, and group workloads into waves by dependency cluster. Exit criteria: every workload has an owner, a strategy, a wave and a recorded dependency set.

| Type | Summary | Points | Labels |
| --- | --- | --- | --- |
| Story | Run Application Discovery Service across the estate | 5 | aws-migration discovery |
| Story | Identify retirement candidates and confirm with owners | 3 | aws-migration discovery |
| Story | Assign a strategy, owner and wave to every workload | 5 | aws-migration discovery |
| Story | Map network dependencies per wave | 5 | aws-migration discovery |

## Landing zone

Account structure, three-tier VPC, hybrid connectivity and guardrails. Exit criteria: terraform apply reproduces the landing zone from empty and hybrid connectivity is tested at real throughput.

| Type | Summary | Points | Labels |
| --- | --- | --- | --- |
| Story | Agree the IPAM plan with the network team | 3 | aws-migration landing-zone |
| Story | Order Direct Connect and stand up backup VPN | 5 | aws-migration landing-zone |
| Story | Build the three-tier VPC with Terraform | 5 | aws-migration landing-zone |

## Platform and pipeline

EKS, ECS Fargate and the EC2 rehost target, plus the CI/CD pipeline that deploys to them. Exit criteria: a commit reaches staging automatically and a rollback has been performed deliberately and timed.

| Type | Summary | Points | Labels |
| --- | --- | --- | --- |
| Story | Provision EKS with IRSA and access entries | 8 | aws-migration platform |
| Story | Provision the EC2 rehost target | 5 | aws-migration platform |
| Story | Provision RDS Postgres Multi-AZ | 5 | aws-migration platform |
| Story | Establish GitHub OIDC deployment roles | 3 | aws-migration platform |
| Story | Build the CI pipeline with a coverage gate | 5 | aws-migration platform |
| Story | Prove rollback by rehearsing it | 3 | aws-migration platform |

## Wave execution

Move workloads wave by wave: build, replicate, test, cut over, validate. Exit criteria: every workload in the wave is validated and its source is decommissioned or formally retained.

| Type | Summary | Points | Labels |
| --- | --- | --- | --- |
| Story | Migrate billing-api (replatform, wave 1) | 5 | aws-migration wave-1 replatform owner-payments |
| Task | Cutover rehearsal for billing-api | 2 | aws-migration wave-1 replatform owner-payments cutover |
| Story | Migrate billing-worker (replatform, wave 1) | 5 | aws-migration wave-1 replatform owner-payments |
| Task | Cutover rehearsal for billing-worker | 2 | aws-migration wave-1 replatform owner-payments cutover |
| Story | Migrate invoice-renderer (rehost, wave 1) | 3 | aws-migration wave-1 rehost owner-payments |
| Task | Cutover rehearsal for invoice-renderer | 2 | aws-migration wave-1 rehost owner-payments cutover |
| Story | Retire legacy-fax-gateway | 2 | aws-migration wave-1 retire owner-facilities |
| Story | Retire print-spooler | 2 | aws-migration wave-1 retire owner-facilities |
| Story | Migrate orders-api (replatform, wave 2) | 5 | aws-migration wave-2 replatform owner-commerce |
| Task | Cutover rehearsal for orders-api | 2 | aws-migration wave-2 replatform owner-commerce cutover |
| Story | Migrate orders-worker (replatform, wave 2) | 5 | aws-migration wave-2 replatform owner-commerce |
| Task | Cutover rehearsal for orders-worker | 2 | aws-migration wave-2 replatform owner-commerce cutover |
| Story | Migrate inventory-sync (rehost, wave 2) | 3 | aws-migration wave-2 rehost owner-commerce |
| Task | Cutover rehearsal for inventory-sync | 2 | aws-migration wave-2 rehost owner-commerce cutover |
| Story | Migrate pricing-engine (refactor, wave 2) | 13 | aws-migration wave-2 refactor owner-commerce |
| Task | Cutover rehearsal for pricing-engine | 2 | aws-migration wave-2 refactor owner-commerce cutover |
| Story | Migrate warehouse-scanner (rehost, wave 2) | 3 | aws-migration wave-2 rehost owner-logistics |
| Task | Cutover rehearsal for warehouse-scanner | 2 | aws-migration wave-2 rehost owner-logistics cutover |
| Story | Migrate crm-connector (repurchase, wave 3) | 8 | aws-migration wave-3 repurchase owner-sales |
| Task | Cutover rehearsal for crm-connector | 2 | aws-migration wave-3 repurchase owner-sales cutover |
| Story | Migrate reporting-etl (replatform, wave 3) | 5 | aws-migration wave-3 replatform owner-data |
| Task | Cutover rehearsal for reporting-etl | 2 | aws-migration wave-3 replatform owner-data cutover |
| Story | Migrate data-warehouse (relocate, wave 3) | 8 | aws-migration wave-3 relocate owner-data |
| Task | Cutover rehearsal for data-warehouse | 2 | aws-migration wave-3 relocate owner-data cutover |
| Story | Migrate ml-feature-store (refactor, wave 3) | 13 | aws-migration wave-3 refactor owner-data |
| Task | Cutover rehearsal for ml-feature-store | 2 | aws-migration wave-3 refactor owner-data cutover |
| Story | Migrate hr-portal (repurchase, wave 4) | 8 | aws-migration wave-4 repurchase owner-people |
| Task | Cutover rehearsal for hr-portal | 2 | aws-migration wave-4 repurchase owner-people cutover |
| Story | Document why payroll-batch is retained this cycle | 1 | aws-migration wave-4 retain owner-people |
| Story | Document why mainframe-bridge is retained this cycle | 1 | aws-migration wave-4 retain owner-core-systems |
| Story | Migrate auth-service (refactor, wave 4) | 13 | aws-migration wave-4 refactor owner-platform |
| Task | Cutover rehearsal for auth-service | 2 | aws-migration wave-4 refactor owner-platform cutover |
| Story | Migrate audit-log-archive (rehost, wave 5) | 3 | aws-migration wave-5 rehost owner-compliance |
| Task | Cutover rehearsal for audit-log-archive | 2 | aws-migration wave-5 rehost owner-compliance cutover |
| Story | Migrate dr-replica (relocate, wave 5) | 8 | aws-migration wave-5 relocate owner-platform |
| Task | Cutover rehearsal for dr-replica | 2 | aws-migration wave-5 relocate owner-platform cutover |

## Post-migration

Hypercare, right-sizing against real demand, cost controls and operational handover. Exit criteria: workloads are owned by the run team with runbooks, dashboards and alarms in place.

| Type | Summary | Points | Labels |
| --- | --- | --- | --- |
| Story | Run two weeks of hypercare per wave | 3 | aws-migration post-migration |
| Story | Right-size workloads after two weeks of data | 3 | aws-migration post-migration |
| Story | Purchase Savings Plans once usage stabilises | 2 | aws-migration post-migration |
| Story | Hand over runbooks, dashboards and alarms | 3 | aws-migration post-migration |
| Story | Decommission source systems after the retention window | 2 | aws-migration post-migration |
