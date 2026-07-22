# Tearing Everything Down

Copilot only manages what it created — anything the **app itself** provisioned at
runtime (DynamoDB tables, its S3 snapshot bucket) is NOT tracked by Copilot and will not
be deleted automatically. Same for anything you set up manually outside Copilot (the
deploy-artifacts S3 bucket, ACM certificate, Route 53 records). Each of those needs
manual cleanup, listed below.

---

## Step 1: Delete services (in reverse dependency order)

```bash
copilot svc delete --name ui      --env <ENV_NAME>
copilot svc delete --name server  --env <ENV_NAME>
copilot svc delete --name vectors --env <ENV_NAME>
copilot svc delete --name metrics --env <ENV_NAME>
```

Each of these deletes the ECS service, task definitions, the service's own CloudFormation
stack, its addons stack (IAM policy), and — importantly — **any EFS access points and the
EFS filesystem itself if it was created with `--lifecycle workload`** (the `ui` volume, if
you followed the main README). Data on that volume is gone once this runs. If you need to
keep it, back it up first (e.g. `copilot svc exec` in and `tar` the volume out, or take an
EFS backup via AWS Backup) before deleting.

If a volume was created with `--lifecycle environment` (the `server` shared-config
volume, if you followed the main README), it survives individual service deletion —
it gets cleaned up in Step 2 instead, when the environment itself is deleted.

`copilot svc delete` will prompt for confirmation per service. Use `--yes` to skip the
prompt if scripting this.

---

## Step 2: Delete the environment

```bash
copilot env delete --name <ENV_NAME>
```

This tears down the VPC, subnets, NAT Gateway (if you added one), ECS cluster, Cloud Map
private hosted zone, ALB (if any `Load Balanced Web Service` existed), and any
`--lifecycle environment` EFS volumes.

---

## Step 3: Delete the app

```bash
copilot app delete
```

This removes the top-level Copilot app construct, the bootstrap IAM roles/StackSets, and
local `copilot/` config. Prompts for confirmation; use `--yes` to skip.

---

## Step 4: Clean up what Copilot never knew about

None of the following gets touched by any `copilot ... delete` command — Copilot has no
awareness these exist at all.

### The app's own self-provisioned AWS resources

The app creates its own DynamoDB tables and S3 snapshot bucket on first run (see the
`Step N [INFO]` setup log messages). If you want a truly clean slate:

```bash
# DynamoDB tables (check exact names against your config.json's instance.id)
aws dynamodb list-tables --query 'TableNames' --output table | grep <TENANT_SHORT_NAME>
aws dynamodb delete-table --table-name <TENANT_SHORT_NAME>-environment-<INSTANCE_ID>
aws dynamodb delete-table --table-name <TENANT_SHORT_NAME>-pql-<INSTANCE_ID>
aws dynamodb delete-table --table-name <TENANT_SHORT_NAME>-token-<INSTANCE_ID>
aws dynamodb delete-table --table-name <TENANT_SHORT_NAME>-brief-<INSTANCE_ID>
aws dynamodb delete-table --table-name <TENANT_SHORT_NAME>-briefrecord-<INSTANCE_ID>
aws dynamodb delete-table --table-name <TENANT_SHORT_NAME>-secrets-<INSTANCE_ID>

# S3 snapshot bucket — must be emptied before it can be deleted
aws s3 rm s3://<TENANT_SHORT_NAME>-snaps-<INSTANCE_ID> --recursive
aws s3 rb s3://<TENANT_SHORT_NAME>-snaps-<INSTANCE_ID>
```

### The deploy-artifacts bucket you created manually

```bash
aws s3 rm s3://<DEPLOY_ARTIFACTS_BUCKET> --recursive
aws s3 rb s3://<DEPLOY_ARTIFACTS_BUCKET>
```

### DNS + TLS, if you set it up (see `DNS-TLS-SETUP.md`)

```bash
# Remove the ALIAS record pointing your subdomain at the (now-deleted) ALB
aws route53 change-resource-record-sets --hosted-zone-id <HOSTED_ZONE_ID> --change-batch '{
  "Changes": [{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "<SUBDOMAIN>.<YOUR_DOMAIN>",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "<ALB_CANONICAL_HOSTED_ZONE_ID>",
        "DNSName": "<ALB_DNS_NAME>",
        "EvaluateTargetHealth": true
      }
    }
  }]
}'

# Remove the ACM validation CNAME record
aws route53 change-resource-record-sets --hosted-zone-id <HOSTED_ZONE_ID> --change-batch '{
  "Changes": [{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "<VALIDATION_RECORD_NAME>",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "<VALIDATION_RECORD_VALUE>"}]
    }
  }]
}'

# Delete the certificate itself (only works once nothing references it, i.e. after Step 2)
aws acm delete-certificate --certificate-arn <CERT_ARN> --region <YOUR_REGION>
```

Note: ACM will refuse to delete a certificate still attached to a listener — this must run
**after** the environment (and its ALB) is deleted in Step 2, not before.

---

## Verify nothing is left billing you

```bash
# No more ECS clusters for this app
aws ecs list-clusters --query 'clusterArns' --output table

# No more EFS filesystems
aws efs describe-file-systems --query 'FileSystems[].{Id:FileSystemId,Name:Name}' --output table

# No more load balancers
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output table

# No more NAT Gateways (if you added one)
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" --query 'NatGateways[].NatGatewayId' --output table

# No more CloudFormation stacks for this app
aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query 'StackSummaries[?contains(StackName, `<APP_NAME>`)].StackName' --output table
```

If any of these still show results after Steps 1–3, something didn't fully tear down —
check the CloudFormation console/CLI for that specific stack's status and events before
manually deleting resources out from under it.
