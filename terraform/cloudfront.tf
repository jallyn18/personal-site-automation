# One distribution serves both the static site and the JSON API.
#
#   /*      -> S3 (private, OAC-signed)
#   /api/*  -> Lambda Function URL (private, OAC-signed, IAM auth)
#
# Putting the API behind the same distribution means the browser makes
# same-origin requests: no CORS preflights, no API Gateway, no second domain.

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${local.name}-s3"
  description                       = "OAC for the static site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_origin_access_control" "lambda" {
  name                              = "${local.name}-lambda"
  description                       = "OAC for the API function URL"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Gatsby emits directory-style pages (/projects/index.html). S3 has no concept
# of a directory index behind CloudFront, so rewrite at the edge.
resource "aws_cloudfront_function" "rewrite_index" {
  name    = "${local.name}-rewrite-index"
  runtime = "cloudfront-js-2.0"
  comment = "Append index.html to extensionless paths"
  publish = true

  code = <<-JS
    function handler(event) {
      var request = event.request;
      var uri = request.uri;

      if (uri.endsWith('/')) {
        request.uri = uri + 'index.html';
      } else if (!uri.includes('.')) {
        request.uri = uri + '/index.html';
      }

      return request;
    }
  JS
}

# TEMPORARY. Remove once the /api/* 404 is resolved.
#
# Everything readable about the API path is correct: the ordered behaviour is
# live (Quantity 1), it targets the lambda origin, and the OAC, function URL
# auth type and resource policy all match what AWS documents. The handler
# answers 200 to a direct invoke, and the function URL answers 200 to a
# correctly signed request. Yet UrlRequestCount shows CloudFront has never sent
# a single request to that function URL.
#
# The public response cannot separate the two remaining explanations, because
# the distribution maps both origin 403 and origin 404 to /404.html: a
# behaviour that never matched and an origin that refused CloudFront produce
# byte-identical replies. Attaching a marker response header would not help
# either, since the error page is served by the default behaviour and carries
# its policy.
#
# So answer it without an origin at all. This function is attached to /api/*
# only and replies to one probe path from the edge itself. A 200 from it proves
# the behaviour matched and moves the fault to the CloudFront-to-Lambda leg; the
# 404 page proves the behaviour is not being applied. Every other path is
# returned unchanged.
resource "aws_cloudfront_function" "api_edge_probe" {
  name    = "${local.name}-api-edge-probe"
  runtime = "cloudfront-js-2.0"
  comment = "Temporary: whether the /api/* behaviour is applied at the edge"
  publish = true

  code = <<-JS
    function handler(event) {
      if (event.request.uri === '/api/__edge-probe') {
        return {
          statusCode: 200,
          statusDescription: 'OK',
          headers: {
            'content-type': { value: 'application/json' },
            'cache-control': { value: 'no-store' }
          },
          body: '{"behaviour":"/api/*"}'
        };
      }

      return event.request;
    }
  JS
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "${local.name}-security-headers"
  comment = "HSTS, CSP and friends for the static site"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    xss_protection {
      protection = true
      mode_block = true
      override   = true
    }

    content_security_policy {
      override = true
      # 'unsafe-inline' on style-src is required by Gatsby's critical-CSS
      # inlining. Scripts stay strict.
      content_security_policy = join("; ", [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self' data:",
        "connect-src 'self'",
        "frame-ancestors 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "object-src 'none'",
      ])
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=(), interest-cohort=()"
      override = true
    }
  }
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.domain_name} static site + API"
  default_root_object = "index.html"
  price_class         = var.cloudfront_price_class
  http_version        = "http2and3"

  aliases = var.enable_custom_domain ? local.all_domains : []

  origin {
    origin_id                = "s3-site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  origin {
    origin_id                = "lambda-api"
    domain_name              = replace(replace(aws_lambda_function_url.api.function_url, "https://", ""), "/", "")
    origin_access_control_id = aws_cloudfront_origin_access_control.lambda.id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rewrite_index.arn
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "lambda-api"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # The API is dynamic; caching is handled per-response by the function's
    # own Cache-Control headers, not at the edge.
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id

    # Temporary, with the function above. Remove both together.
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.api_edge_probe.arn
    }
  }

  # Gatsby builds a 404.html; S3 returns 403 for missing keys under OAC.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  dynamic "viewer_certificate" {
    for_each = var.enable_custom_domain ? [1] : []

    content {
      acm_certificate_arn      = aws_acm_certificate_validation.site[0].certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }

  dynamic "viewer_certificate" {
    for_each = var.enable_custom_domain ? [] : [1]

    content {
      cloudfront_default_certificate = true
    }
  }
}
