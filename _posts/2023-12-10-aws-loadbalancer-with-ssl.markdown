---
layout: post
title: "Hosting with AWS (Part 3)"
subtitle: "enrypting traffic and add a domain name for serving your website"
description: "How to utilize ACM and Route53 to expose your webserver with proper domain name"
date: 2023-12-01 00:00:00
background_color: '#ec7211'
---

In our [previous post]({% link _posts/2023-12-01-aws-web-hosting.markdown %}) we learnt:

- How to create a separate Private Cloud for your application
- Using AutoScaling and ECS to spinup and manage EC2 instances running your server code
- How to use a Load Balancer across multiple subnets to server requests to your EC2 instances

But we exposed `:80` port to handle incoming requests. Traffic to port 80 is generally for unencrypted traffic. In this article
we will expose port `:443`, so that we can handle encrypted requests to our webserver (not the webserver but the lb in this case).

*If you are asking why we need it, you have probably skipped some early stages of development. Checkout how to secure APIs, as a starting point*

<p>&nbsp;</p>

### Prerequisites

- Publicly registered domain name. Here we are using [GoDaddy](https://godaddy.com/en-in)
- Money, because AWS charges on traffic coming from the outside world into aws servers.

<p>&nbsp;</p>

### Building Blocks

__DNS__

DNS translates human-friendly domain names (e.g., google.in) into machine-readable IP addresses. IP's are how you connect to different machines which serves you the response to your requests. Like a phone book.

There are different types of records that can be added to a DNS server, like:
- `A` records (mapping domain names to IP addresses)
- `MX` records (routing emails), and
- `CNAME` records (aliases pointing to other domains)

[DNS servers](https://www.cloudflare.com/learning/dns/dns-server-types/) can be of multiple type, like:
- a `TLD` record is `Top level domain server`, like `.com`, `.org` etc.
- `Authoritative Nameserver`, which provides the `recursive nameservers` with the ip address incase its not cached.

{% preview "https://www.cloudflare.com/learning/dns/what-is-dns/" %}

__DNS Zones__

DNS zone is something of namespacing, where a certain entity(organisation/individual) is responsible for maintaing their DNS servers.

When a web browser or other network device needs to find the IP address for a hostname such as “example.com”, it performs a DNS lookup - essentially a DNS zone check - and is taken to the DNS server that manages the DNS zone for that hostname. This server is called the `Authoritative NS` for the domain.

The authoritative name server then resolves the DNS lookup by providing the IP address, or other data, for the requested hostname.

{% preview "https://www.cloudflare.com/learning/dns/glossary/dns-zone/" %}

[Route53](https://docs.aws.amazon.com/route53/) is what AWS uses as its `Domain Name` service. And each `Hosted Zone` is a `DNS` zone.

When you create a hosted zone in Route 53, four NS records are automatically assigned. These records point to Route 53 servers, entrusted with resolving your domain name and directing traffic towards your website or application.

Here is an [article](https://www.liquidweb.com/kb/how-to-demystify-the-dns-process/) which gives you an idea about `DNS` name resoultion works.


Inorder to enable `HTTPS` requests, we also need to generate `SSL certificates`. This is usually done with something like `letsencrypt`. Each SSL certificate also has an expiration date, and hence it needs to be renewed for your `public domain name`.

The loadbalancer or the fronting proxy would then take care of terminating the ssl connection, and sending the decrypted requests to the EC2 instances.

In AWS the certificate management is done using [ACM](https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html). This is the easiest to do.

The `LoadBalancer` uses these certificate arn to terminate and decrypt requests.

<p>&nbsp;</p>

### Code

Since we already have the gist, I will only be posting the code changes.

```terraform
resource "aws_acm_certificate" "konoha_in" {
  domain_name               = "konoha.in"
  subject_alternative_names = ["*.konoha.in"]
  validation_method         = "DNS"

  tags = {
    Environment = "prod"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_zone" "konoha_in" {
  name = "konoha.in"
}

resource "aws_route53_record" "konoha_acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.konoha_in.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = aws_route53_zone.konoha_in.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [
    each.value.record,
  ]

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "konoha_in" {
  certificate_arn         = aws_acm_certificate.konoha_in.arn
  validation_record_fqdns = [for record in aws_route53_record.konoha_acm_validation : record.fqdn]
}

resource "aws_route53_record" "konoha_app_route_alias" {
  zone_id = aws_route53_zone.konoha_in.zone_id
  name    = "api.${aws_route53_zone.konoha_in.name}"
  type    = "A"
  alias {
    name                   = aws_lb.app_lb.dns_name
    zone_id                = aws_lb.app_lb.zone_id
    evaluate_target_health = true
  }
}
```

```diff
resource "aws_lb_listener" "app_lb_listener" {
     load_balancer_arn = aws_lb.app_lb.arn
-    port = "80"
-    protocol = "HTTP"
+    port = "443"
+    protocol = "HTTPS"
+    certificate_arn   = aws_acm_certificate.konoha_in.arn
+    ssl_policy = "ELBSecurityPolicy-2016-08"
+
+    depends_on = [ aws_acm_certificate_validation.konoha_in ]
```

- Here, we have assumed that we have registered a domain name `konoha.in` in GoDaddy.
- First, we create certificates for our public domain name.
- In Route53 we create a hosted zone, this will have 4 nameservers (NS records) and an SOA record (metadata on domain name)

Now we need a way to be able to associate and validate the issued certificate with the domain name. In order to validate we can either do:
- DNS Validation
- Email Validation

We will use [DNS Validation](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html).
> When you choose DNS validation, ACM provides you with one or more CNAME records that must be added to this database. These records contain a unique key-value pair that serves as proof that you control the domain.

The `aws_route53_record` block does just that. You can check this, by going to your `ACM` dashboard and `Route53` dashboard.
After `terraform apply` inside the `hosted zone` in `Route53` you can see the entry, and it should match the `CNAME` record key value provided in the `ACM` dasboard.

- We also create another `A` (Alias) record, which points a subdomain `api.konoha.in` to the `LoadBalancer`
- We are waiting for the certificate validation to commence, This essentially changes the state of the validation from `Pending` to `Success`, and the certificate is ready to be used for that domain name.
- We also changed the LoadBalancer `port` to `:443` and attach the `certificate arn` to use for terminating.

<p>&nbsp;</p>

__Final Piece__

You now need to go to daddy and change the DNS entries. In your UI you should see `Nameservers` tab, apart from `Records`.
Replace the existing nameserver with the ones provided in the `Route 53 hosted zone`.


The other way of doing this, is by adding the `ACM` generated `CNAME` to the `DNS Records` instead of `Nameservers`, but for
some reason my certificate wouldn't get validate. The __disadvantage__ with this approach is you now need to configure `MX` records in `AWS`. You can check it [here](https://renehernandez.io/tutorials/terraforming-dns-with-aws-route53/). 

Maybe we will explore it at a later date.

<p>&nbsp;</p>

### Conclusion:

This kindof marks the end of basic hosting using `AWS`. There is a separate [gist](https://gist.github.com/ikouchiha47/d24503d048cddfd56f86fd98be453442#file-aws_deploy_ssl-tf) with the above changes.



### References:

- [AWS Route53 videos](https://aws.amazon.com/route53/resources/)
- [Hosting with Godaddy and AWS](https://jryancanty.medium.com/domain-by-godaddy-dns-by-route53-fc7acf2f5580)
- [AWS Route53 FAQs](https://aws.amazon.com/route53/faqs/)
