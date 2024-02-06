---
layout: post
title: "Hosting with AWS (Part 3)"
subtitle: "setting up nameserver, enabling https capability and accessing public domain"
description: "Using route53 and aws certificate manager expose your service to the internet"
date: 2023-12-10 00:00:00
background_color: '#ec7211'
---

In our [previous post]({% link _posts/2023-12-10-aws-loadbalancer-with-ssl.markdown %}) we setup an AutoScaling and ECS task definition to spinup and manage EC2 instances (which is running our application server).
We also created a separate __VPC__ to handle incoming traffic and forward it to an __ALB__.

We attached an __Internet Gateway__ to the `VPC` to allow interraction with the outside internet. The `LB` takes care of forwarding the traffic to the proper VMs depending on the conditions, and which autoscaling groups are the target.

<p>&nbsp;</p>

In this article we are going to wrap up the simple setup, by allowing users to access our server via a domain name. And enabling AWS to receive HTTPS traffic, thereby enabling secure communication between client and server.

### Requirements

- domain name registered publicly
- aws route53 and acm (certificate manager)
- money


#### Domain Name

For this you will have to register a domain name. I prefer [hoistinger](https://www.hostinger.in), but we are goinf to have to bear with [GoDaddy](https://www.godaddy.com/en-in) for now. _because of the project requirements_.

AWS might be free but if you are serving requests via route53, which you have to for the HTTPS thing, AWS will charge you on internet traffic.

Lets assume the domain name is `istope.in`

<p>&nbsp;</p>

### AWS Route53 and AWS CM

`Route53` is what you call a DNS service. DNS service has a bunch of records, like `CNAME`, `A` records. `ACM` is the certificate manager which is used to generate and renew `ssl certificates` for allowing HTTPS traffic.

`Godaddy` also provides us with its own DNS service, where one can provide DNS records, But we are going to use `AWS`s for now.


DNS is broken up into multiple zones, which are responsible for maintaining a subset of domains. The subsetting is mostly done depending on various rules and scenarios. Each zone can be thought of as a file with dns records entries in the file.


{% preview "https://www.cloudflare.com/learning/dns/glossary/dns-zone/" %}

Similarly, `Route53` allows/requires us to create hosted zones for each of your root domains.

> A hosted zone is an Amazon Route 53 concept. A hosted zone is analogous to a traditional DNS zone file; it represents a collection of records that can be managed together, belonging to a single parent domain name

https://aws.amazon.com/route53/faqs/

When you create a `hosted zone` you get a bunch of __4 nameservers__. These nameservers would be responsible for resolving domain and subdomain names.


A [Certificate Manager](https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html) is responsible for issuing public certificates for your public DNS. It does this, by creating a CNAME record which specifies a unique value which allows to identify your ownership of a domain.

{% preview "https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html" %}

The Certificate validation can be done either via DNS validation or Email validation. We are going to use DNS validation here. The manual setup is presented in [this blog on aws](https://aws.amazon.com/blogs/security/easier-certificate-validation-using-dns-with-aws-certificate-manager/)

<p>&nbsp;</p>

### Subdomain and Serving requests in Route53

Now that SSL certificate generation is done, we also need to serve our requests. These requires connecting/aliasing a domain name to the loadbalancer URL.

We could also, point the parent domain, `isotope.in` to a cloudfront url for serving a static website, but we want something like `api.isotope.in` to point to our deployed application server.


### Implementation

Since this in continuation with the previous article, I am going to show you the diff. The changes required are pretty self explanatory. Figuring out connection issues, certificate status not changing, dns not resolving are the main issues that need to be addressed.

```diff
provider "aws" {
   region = "ap-south-1"
+  profile = var.AWS_PROFILE
 }
 
+// create certificates
+
+resource "aws_acm_certificate" "isotope_in" {
+  domain_name               = "isotope.in"
+  subject_alternative_names = ["*.isotope.in"]
+  validation_method         = "DNS"
+
+  tags = {
+    Environment = "prod"
+  }
+
+  lifecycle {
+    create_before_destroy = true
+  }
+}
+
+resource "aws_route53_zone" "isotope_in" {
+  name = "isotope.in"
+}
+
+resource "aws_route53_record" "isotope_acm_validation" {
+  for_each = {
+    for dvo in aws_acm_certificate.isotope_in.domain_validation_options : dvo.domain_name => {
+      name   = dvo.resource_record_name
+      record = dvo.resource_record_value
+      type   = dvo.resource_record_type
+    }
+  }
+
+  zone_id = aws_route53_zone.isotope_in.zone_id
+  name    = each.value.name
+  type    = each.value.type
+  ttl     = 60
+  records = [
+    each.value.record,
+  ]
+
+  allow_overwrite = true
+}
+
+resource "aws_acm_certificate_validation" "isotope_in" {
+  certificate_arn         = aws_acm_certificate.isotope_in.arn
+  validation_record_fqdns = [for record in aws_route53_record.isotope_acm_validation : record.fqdn]
+}
+
+resource "aws_route53_record" "isotope_app_route_alias" {
+  zone_id = aws_route53_zone.isotope_in.zone_id
+  name    = "api.${aws_route53_zone.isotope_in.name}"
+  type    = "A"
+  alias {
+    name                   = aws_lb.isotope_lb.dns_name
+    zone_id                = aws_lb.isotope_lb.zone_id
+    evaluate_target_health = true
+  }
+}
+
 resource "aws_lb_listener" "app_lb_listener" {
     load_balancer_arn = aws_lb.app_lb.arn
-    port = "80"
-    protocol = "HTTP"
+    port = "443"
+    protocol = "HTTPS"
+    certificate_arn   = aws_acm_certificate.isotope_in.arn
+    ssl_policy = "ELBSecurityPolicy-2016-08"
+
+    depends_on = [ aws_acm_certificate_validation.isotope_in ]
     default_action {
      type = "fixed-response"

      fixed_response {
       content_type = "text/plain"
       message_body = "HEALTHY"
       status_code  = "200"
     }
    }
}
```
*ecs_deply.tf*

In your output.tf file you can print this by adding an entry 

```terraform
output "dns_name" {
  description = "The DNS name of the load balancer."
  value       = aws_lb.app_lb.dns_name
}

output "acm_setup" {
  value = "Test this demo code by going to https://${aws_route53_record.isotope_app_route_alias.fqdn} and checking your have a valid SSL cert"
}
```



As you run `terraform apply` on it. You should see, 2 entries in your certificate manager you created, which will provide you the required CNAME entries, which ACM will use for certificate management.

And in your `Route53` console, you should see 4 entries:
1. List of nameservers NS records
2. And SOA record
2. The CNAME record required by ACM (created automatically)
3. An entry api.isotope.in pointing to the loadbalncer domain name.


In case the `terraform apply` fails due to timeout. You can still go to the `Route53` dashboard, and get the `NS` records for your hosted zone.

You need to __copy the NS records from AWS and put it in Godaddy's Nameserver tab__.


### Conclusion

You can wait for sometime and then run a curl on your healthcheck api to see the response getting returned.

```shell
$> curl https://isotope.in/konoha/api/ping
pong%
```
