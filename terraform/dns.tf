# The hosted zone is either created here or adopted from one that already
# exists, depending on whether route53_zone_id is set.
#
# Adopting is a data source rather than an imported resource on purpose. A zone
# that predates this stack -- created by a Route53 domain registration, or by
# hand -- outlives it too, and `terraform destroy` should not be able to delete
# the DNS for a domain this stack merely publishes a website on. Terraform
# manages the records it owns inside the zone; it does not own the zone.
#
# When creating, copy the `nameservers` output into your registrar's NS records
# after the first apply. Until that delegation propagates ACM validation cannot
# complete, which is what enable_custom_domain exists to work around.

resource "aws_route53_zone" "primary" {
  count = var.route53_zone_id == "" ? 1 : 0

  name    = var.domain_name
  comment = "Managed by ${var.github_owner}/${var.automation_repo}"
}

data "aws_route53_zone" "existing" {
  count = var.route53_zone_id == "" ? 0 : 1

  zone_id = var.route53_zone_id

  lifecycle {
    postcondition {
      # Catches a zone id pasted from the wrong domain before any record is
      # written into it.
      condition     = trimsuffix(self.name, ".") == var.domain_name
      error_message = "route53_zone_id points at zone '${self.name}', but domain_name is '${var.domain_name}'. Records would be written into the wrong zone."
    }
  }
}

resource "aws_acm_certificate" "site" {
  count = var.enable_custom_domain ? 1 : 0

  provider = aws.us_east_1

  domain_name               = var.domain_name
  subject_alternative_names = local.subject_alternative_names
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# One validation record per distinct name on the certificate. ACM emits
# identical CNAMEs for names in the same zone, so the map dedupes on record name.
resource "aws_route53_record" "cert_validation" {
  for_each = var.enable_custom_domain ? {
    for dvo in aws_acm_certificate.site[0].domain_validation_options :
    dvo.resource_record_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  count = var.enable_custom_domain ? 1 : 0

  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  timeouts {
    create = "15m"
  }
}

# Alias records cost nothing to resolve and support the apex, which a CNAME cannot.
resource "aws_route53_record" "apex_a" {
  count = var.enable_custom_domain ? 1 : 0

  zone_id = local.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "apex_aaaa" {
  count = var.enable_custom_domain ? 1 : 0

  zone_id = local.zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www_a" {
  count = var.enable_custom_domain ? 1 : 0

  zone_id = local.zone_id
  name    = local.www_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www_aaaa" {
  count = var.enable_custom_domain ? 1 : 0

  zone_id = local.zone_id
  name    = local.www_domain
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

# Publishes "this domain sends no mail", which stops it being an easy spoofing
# target.
#
# Opt-in, and default off, because it is destructive to a domain that does send
# mail: "v=spf1 -all" tells every receiver to reject messages from it, and this
# would also overwrite an existing apex TXT record such as a domain
# verification token. Only enable it once you know the zone carries no mail
# configuration you care about.
resource "aws_route53_record" "spf_reject" {
  count = var.manage_email_dns ? 1 : 0

  zone_id = local.zone_id
  name    = var.domain_name
  type    = "TXT"
  ttl     = 3600
  records = ["v=spf1 -all"]
}

# No rua= address. Aggregate reports would be empty -- the SPF record above
# declares that this domain sends no mail at all -- and publishing a personal
# address in a TXT record is a standing invitation to every harvester on the
# internet. The reject policy is the part that does the work.
resource "aws_route53_record" "dmarc" {
  count = var.manage_email_dns ? 1 : 0

  zone_id = local.zone_id
  name    = "_dmarc.${var.domain_name}"
  type    = "TXT"
  ttl     = 3600
  records = ["v=DMARC1; p=reject;"]
}
