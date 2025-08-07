# Required Permissions for AWS
In order to have the right permissions for AWS to work, we encourage that you create something following these links:
- DDNS-Updater [Route53 Docs](https://github.com/qdm12/ddns-updater/blob/v2.8.0/docs/route53.md#domain-setup)
- [Traefik/ACME Route53 Docs](https://go-acme.github.io/lego/dns/route53/#least-privilege-policy-for-production-purposes)
- [Traefil Docs](https://doc.traefik.io/traefik/https/acme/)

A simple implementation in Terraform of this can be found below:
```hcl
locals {
    eth_name_prefix ="eth-ddns"
    eth_com_zone_id = aws_route53_zone.eth_com.zone_id # needs to be created somehwere
}

resource "aws_iam_user" "tools_eth_route53_updater" {
  name = "${local.eth_name_prefix}-route53-updater"
}

resource "aws_iam_access_key" "tools_eth_route53_key" {
  user    = aws_iam_user.tools_eth_route53_updater.name
  depends_on = [aws_iam_user.tools_eth_route53_updater]
}

resource "aws_secretsmanager_secret" "tools_eth_route53_secret" {
  name        = "/eth/ddns/${local.eth_name_prefix}-route53-updater-credentials"
  description = "Rotated IAM credentials for route53-updater"
}

resource "aws_secretsmanager_secret_version" "tools_eth_route53_secret_version" {
  secret_id     = aws_secretsmanager_secret.tools_eth_route53_secret.id
  secret_string = jsonencode({
    accessKeyId     = aws_iam_access_key.tools_eth_route53_key.id
    secretAccessKey = aws_iam_access_key.tools_eth_route53_key.secret
    username        = aws_iam_user.tools_eth_route53_updater.name
  })
}

# scoped down permissions for DDNS CNAMEs
resource "aws_iam_policy" "allow_change_record_sets_general" {
  name   = "AllowChangeRecordSetsOnA30888"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = "route53:ChangeResourceRecordSets",
        Resource = "arn:aws:route53:::hostedzone/${local.eth_bci_glxy_com_zone_id}"
      }
    ]
  })
}

# very scoped down permissions for ACME
resource "aws_iam_policy" "acme_challenge_permissions" {
  name   = "AcmeChallengePermissions"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = "route53:GetChange",
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Effect = "Allow",
        Action = "route53:ListHostedZonesByName",
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = "route53:ListResourceRecordSets",
        Resource = "arn:aws:route53:::hostedzone/${local.eth_com_zone_id}"
      },

    ]
  })
}
```
