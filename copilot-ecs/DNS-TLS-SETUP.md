# Custom Domain + HTTPS Setup

Copilot's ALB only gets an HTTP listener by default. The bare `*.elb.amazonaws.com`
hostname can never get a real, browser-trusted certificate — public CAs (including ACM)
won't issue a certificate for a domain you don't own. To get HTTPS, you need:

1. A domain you control, with a public Route 53 hosted zone.
2. An ACM certificate for a subdomain, DNS-validated via a record in that hosted zone.
3. That certificate attached to the environment.
4. An `alias` on the service's manifest matching the certificate's domain.
5. A DNS record pointing your chosen subdomain at the ALB.

Do this as a follow-up once the base deployment is confirmed working over plain HTTP —
it's a meaningfully separate piece of setup, and mistakes here (wrong validation record,
mismatched region) are easy to make and easy to debug independently.

---

## Prerequisites

- A domain with a **public** Route 53 hosted zone already in your AWS account. Check with:
  ```bash
  aws route53 list-hosted-zones --query 'HostedZones[].{Name:Name,Id:Id}' --output table
  ```
  If you don't have one, either register a domain through Route 53, or delegate an
  existing domain's nameservers to a Route 53 hosted zone you create.
- The ACM certificate must be requested in the **same region as your ALB** (the Copilot
  environment's region) — not `us-east-1` unless that's genuinely where your environment
  lives. (`us-east-1` is only special-cased for CloudFront, not for regional ALBs.)

---

## Step 1: Request the certificate

Pick a subdomain for the service you're exposing (e.g. `ui`):

```bash
aws acm request-certificate \
  --domain-name <SUBDOMAIN>.<YOUR_DOMAIN> \
  --validation-method DNS \
  --region <YOUR_REGION> \
  --query 'CertificateArn' --output text
```

This returns a certificate ARN, and puts the cert into `PENDING_VALIDATION`. Get the DNS
validation record ACM wants you to create:

```bash
aws acm describe-certificate --certificate-arn <CERT_ARN> --region <YOUR_REGION> \
  --query 'Certificate.DomainValidationOptions'
```

This returns something like:
```json
[
  {
    "DomainName": "<SUBDOMAIN>.<YOUR_DOMAIN>",
    "ResourceRecord": {
      "Name": "_<RANDOM_HEX>.<SUBDOMAIN>.<YOUR_DOMAIN>.",
      "Type": "CNAME",
      "Value": "_<RANDOM_HEX>.<RANDOM_STRING>.acm-validations.aws."
    }
  }
]
```

---

## Step 2: Create the validation record

Create the CNAME record ACM asked for, in your hosted zone:

```bash
aws route53 change-resource-record-sets --hosted-zone-id <HOSTED_ZONE_ID> --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "<VALIDATION_RECORD_NAME>",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "<VALIDATION_RECORD_VALUE>"}]
    }
  }]
}'
```

ACM polls for this automatically — validation usually completes within a few minutes when
the hosted zone is in the same account. Check status with:
```bash
aws acm describe-certificate --certificate-arn <CERT_ARN> --region <YOUR_REGION> \
  --query 'Certificate.Status'
# → wait for "ISSUED"
```

---

## Step 3: Attach the certificate to the environment

Edit `environments/<ENV_NAME>/manifest.yml` (see `manifests/env-manifest.yml` in this
directory for the exact block):

```yaml
http:
  public:
    certificates:
      - <CERT_ARN>
```

Redeploy the environment to add the HTTPS listener to the ALB:
```bash
copilot env deploy --name <ENV_NAME>
```

---

## Step 4: Add the alias to the service manifest

Edit the target service's manifest (e.g. `copilot/ui/manifest.yml`):

```yaml
http:
  path: '/'
  alias: <SUBDOMAIN>.<YOUR_DOMAIN>
```

Redeploy the service:
```bash
copilot svc deploy --name ui --env <ENV_NAME>
```

---

## Step 5: Point your domain at the ALB

Get the ALB's DNS name and hosted zone ID:
```bash
copilot svc show --name ui --env <ENV_NAME>
# or, directly:
aws elbv2 describe-load-balancers --query 'LoadBalancers[].{DNSName:DNSName,HostedZoneId:CanonicalHostedZoneId}'
```

Create an ALIAS record (not a plain CNAME — ALIAS records are Route 53-specific and work
at the zone apex too, and don't cost you an extra DNS lookup) pointing your subdomain at
the ALB:

```bash
aws route53 change-resource-record-sets --hosted-zone-id <HOSTED_ZONE_ID> --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
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
```

---

## Step 6: Verify

```bash
curl -v https://<SUBDOMAIN>.<YOUR_DOMAIN>
```

Confirm the certificate chain is valid and the response matches what you get hitting the
ALB directly over HTTP. Open it in a browser and confirm the padlock shows a valid,
trusted connection — no more "Not Secure" warning.

If you want to force HTTP → HTTPS redirects, that requires an additional listener rule
edit; Copilot doesn't do this automatically once you add a certificate. Check the current
Copilot manifest docs for the `http.redirect_to_https` (or equivalent) field for your
installed CLI version, since this option has moved/renamed across releases.
