# Runbook: provision, deploy, roll back

Every infrastructure change goes through Terraform, and every workload change
goes through Helm. Don't make console changes. If an emergency forces one,
codify it in a PR within 24 hours.

## 0. One-time account bootstrap

```bash
cd terraform/bootstrap
terraform init
terraform apply -var bucket_name=<org>-platform-tfstate-<region>
```

This creates a versioned, KMS-encrypted, TLS-only state bucket. Pass
`-var create_dynamodb_lock_table=true` only if some clients are still on
Terraform older than 1.10. Newer clients use S3-native locking
(`use_lockfile = true`).

## 1. Provision or update an environment

```bash
cd terraform/envs/staging
cp backend.hcl.example backend.hcl            # fill in the bucket name
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan \
  -var 'allowed_account_ids=["<staging-account-id>"]' \
  -var 'cluster_admin_principal_arns=["arn:aws:iam::<id>:role/<sso-admin-role>","arn:aws:iam::<id>:role/<ci-deploy-role>"]'
terraform apply tfplan
```

Checklist before you apply to **prod**:

- [ ] The plan was reviewed in a PR, and the CI `terraform` workflow passed (fmt, validate, mock-plan tests, tflint, trivy).
- [ ] The plan shows no `destroy`/`replace` on `aws_db_instance`, `aws_elasticache_replication_group` or `aws_eks_cluster` unless that was the intent.
- [ ] `allowed_account_ids` is set (the provider refuses to touch any other account).

## 2. Cluster add-ons (after the first apply)

```bash
aws eks update-kubeconfig --name pb-staging --region us-east-1

# Karpenter: IAM, queue and Pod Identity association already exist from Terraform
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace kube-system --version <pinned> \
  --set settings.clusterName=pb-staging \
  --set settings.interruptionQueue="$(terraform output -json karpenter | jq -r .interruption_queue)" \
  --set tolerations[0].key=CriticalAddonsOnly,tolerations[0].operator=Exists
kubectl apply -f platform/karpenter/      # adjust names for staging

# Observability and secrets
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace --version 93.9.0
helm upgrade --install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
```

## 3. Deploy a service

Images are built by CI, pushed to ECR with an **immutable** tag (the git SHA),
and deployed by digest:

```bash
helm upgrade --install demo-api charts/service \
  --namespace demo --create-namespace \
  -f deploy/demo-api/values-prod.yaml \
  --set image.repository=<ecr-url>/demo-api \
  --set image.digest=sha256:<digest> \
  --atomic --wait --timeout 5m
helm test demo-api -n demo
```

`--atomic` rolls back automatically if pods don't become Ready inside the
timeout. Because the Deployment uses `maxUnavailable: 0`, serving capacity
never drops during a rollout. The PDB (`maxUnavailable: 1`) and topology
spread keep replicas across AZs while Karpenter consolidates nodes.

Verify the release:

```bash
kubectl -n demo rollout status deploy/demo-api
kubectl -n demo get hpa,pdb,pods -o wide
# error rate over the last 5 minutes (should be ~0)
sum(rate(http_requests_total{namespace="demo",code=~"5.."}[5m])) / sum(rate(http_requests_total{namespace="demo"}[5m]))
# backend failures
sum(rate(llm_errors_total{namespace="demo"}[5m]))
```

## 4. Roll back

### Application

```bash
helm history demo-api -n demo                    # find the last good REVISION
helm rollback demo-api <REVISION> -n demo --wait --timeout 5m
helm test demo-api -n demo
```

Rollback re-deploys the previous **digest**. Because ECR tags are immutable and
the lifecycle policy keeps the last 100 tagged images in prod, the previous
image is guaranteed to still exist.

If Helm itself is wedged (`another operation is in progress`):

```bash
helm history demo-api -n demo | tail -3          # identify the pending-* revision
helm rollback demo-api <last-deployed-revision> -n demo
```

### Infrastructure

Terraform has no `rollback`; you revert the commit and re-apply:

```bash
git revert <sha>              # PR, review, merge
terraform plan -out=tfplan && terraform apply tfplan
```

For data stores, a revert isn't enough:

| Situation | Action |
|---|---|
| Bad schema migration | Restore PITR to a **new** instance: `aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier pb-prod-pg --target-db-instance-identifier pb-prod-pg-restore --restore-time <UTC>`. Validate it, then switch the app's DB host through its secret. |
| Parameter group change broke the DB | Revert the commit and apply. `shared_preload_libraries` is `pending-reboot`, so schedule a reboot in the maintenance window. |
| Cache data corrupted | Cache data is disposable. `FLUSHALL` via an admin pod, or restore from the latest snapshot (prod keeps 7 days). |
| EKS upgrade issue | Control-plane upgrades can't be downgraded. Roll **nodes** back by pinning the previous AMI in the EC2NodeClass (`amiSelectorTerms: [{alias: al2023@<version>}]`) and pin add-on versions with `addon_versions`. |

## 5. Local rehearsal

Rehearse every chart change locally first. This exercises the same chart,
NetworkPolicy and ServiceMonitor path:

```bash
make local-up && make local-test && make local-down
```
