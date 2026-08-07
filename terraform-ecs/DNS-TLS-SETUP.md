# Custom Domain + HTTPS Setup (Route 53 + ACM)

The public ALB (`aws_lb.public`, fronting `ui`) only gets an HTTP listener by default, matching
Copilot's own default in `../copilot-ecs/DNS-TLS-SETUP.md`. The bare
`*.elb.amazonaws.com` hostname can never get a real, browser-trusted certificate — public CAs
(including ACM) won't issue one for a domain you don't own. To get HTTPS, you need:

1. A domain you control, with a **public** Route 53 hosted zone.
2. An ACM certificate for that domain, DNS-validated via a record in that hosted zone.
3. A new HTTPS listener on the public ALB, using that certificate.
4. A Route 53 alias record pointing your domain at the ALB.

Unlike the Copilot version, all of this is expressed as Terraform resources — no separate CLI
choreography once the hosted zone exists, and no "redeploy the environment, then redeploy the
service" two-step. Do this as a follow-up once the base HTTP deployment (`README.md`) is
confirmed working — it's a meaningfully separate piece of setup.

## Prerequisites

- A domain with a **public** Route 53 hosted zone already in your AWS account:
  ```bash
  aws route53 list-hosted-zones --query 'HostedZones[].{Name:Name,Id:Id}' --output table
  ```
  If you don't have one, either register a domain through Route 53, or delegate an existing
  domain's nameservers to a Route 53 hosted zone you create.
- ACM certificates for a regional ALB (this one) must be requested in the **same region** as the
  ALB — not `us-east-1` unless that's genuinely your `aws_region`. (`us-east-1` is only
  special-cased for CloudFront, not for regional ALBs.)

## Step 1: Add the Terraform resources

Add a new file, `route53_tls.tf`, alongside the existing `.tf` files:

```hcl
variable "domain_name" {
  description = "Domain to expose ui on, e.g. app.example.com. Leave null to skip HTTPS."
  type        = string
  default     = null
}

variable "route53_zone_name" {
  description = "The public Route 53 hosted zone that owns domain_name, e.g. example.com."
  type        = string
  default     = null
}

data "aws_route53_zone" "this" {
  count = var.domain_name != null ? 1 : 0
  name  = var.route53_zone_name
}

resource "aws_acm_certificate" "ui" {
  count             = var.domain_name != null ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "ui_cert_validation" {
  for_each = var.domain_name != null ? {
    for dvo in aws_acm_certificate.ui[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "ui" {
  count                   = var.domain_name != null ? 1 : 0
  certificate_arn         = aws_acm_certificate.ui[0].arn
  validation_record_fqdns = [for r in aws_route53_record.ui_cert_validation : r.fqdn]
}

resource "aws_lb_listener" "public_https" {
  count             = var.domain_name != null ? 1 : 0
  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.ui[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }
}

resource "aws_route53_record" "ui_alias" {
  count   = var.domain_name != null ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.public.dns_name
    zone_id                = aws_lb.public.zone_id
    evaluate_target_health = true
  }
}
```

`aws_lb.public`, `aws_lb_target_group.ui`, and `var.aws_region` already exist in `alb.tf` /
`variables.tf` — this file only adds new resources, it doesn't touch the existing HTTP listener.

## Step 2: Set the two new variables and apply

```bash
# in terraform.tfvars
domain_name       = "<SUBDOMAIN>.<YOUR_DOMAIN>"
route53_zone_name = "<YOUR_DOMAIN>"   # the hosted zone name, not the subdomain
```

```bash
terraform apply
```

`aws_acm_certificate_validation` blocks the apply until ACM confirms the certificate is
`ISSUED` — this is normally a few minutes when the hosted zone is in the same account, since
Terraform creates the validation CNAME record itself and ACM polls for it automatically. There's
no separate "wait, then create the validation record, then wait again" step like the Copilot/CLI
flow requires; one `apply` does all of it, in dependency order.

If it times out (default 45 minutes) rather than fails outright, check that
`route53_zone_name` is the zone's actual name (e.g. `example.com`, trailing dot optional) and
that the zone is genuinely public, not private.

## Step 3: (Optional) redirect HTTP to HTTPS

Once the HTTPS listener exists, change the existing HTTP listener's `default_action` in `alb.tf`
from a forward to a redirect:

```hcl
resource "aws_lb_listener" "public_http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
```

Do this only after confirming HTTPS works — reverting is just re-applying the original
`forward` action if something's wrong.

## Step 4: Verify

```bash
curl -v https://<SUBDOMAIN>.<YOUR_DOMAIN>
```

Confirm the certificate chain is valid and the response matches what you get hitting the ALB's
own DNS name directly over HTTP (`terraform output public_alb_dns_name`). Open it in a browser
and confirm the padlock shows a valid, trusted connection.

## Tearing down

`terraform destroy` removes the certificate, validation record, HTTPS listener, and alias record
along with everything else, in the correct order — no separate manual ACM/Route53 cleanup, unlike
the DynamoDB/S3 self-provisioned resources called out in the main `README.md`.
