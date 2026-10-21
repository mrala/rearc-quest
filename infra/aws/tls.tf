# Self-signed certificate imported into ACM for the ALB's HTTPS listener (ADR-0003).
# RSA 2048 is accepted by ACM and billed at the standard load balancer rate.
# The ALB DNS name is unknown until the ALB exists, so the cert covers the
# regional ELB wildcard. Clients still do not trust it: use `curl -k`.
resource "tls_private_key" "alb" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb" {
  private_key_pem = tls_private_key.alb.private_key_pem

  subject {
    common_name  = "quest.${var.region}.elb.amazonaws.com"
    organization = "quest (self-signed)"
  }

  dns_names             = ["*.${var.region}.elb.amazonaws.com"]
  validity_period_hours = 24 * 30
  early_renewal_hours   = 24
  is_ca_certificate     = false

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "alb" {
  private_key      = tls_private_key.alb.private_key_pem
  certificate_body = tls_self_signed_cert.alb.cert_pem

  tags = { Name = "${local.name}-self-signed" }

  # The listener uses this certificate, so a replacement must exist first.
  lifecycle {
    create_before_destroy = true
  }
}
