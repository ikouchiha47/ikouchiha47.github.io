---
active: true
layout: post
title: "Hosting with AWS"
subtitle: "utilizing AWS free tier host your server on EC2 instances"
description: "How to utilize AWS Free tier to host webserver"
date: 2023-11-30 00:00:00
background_color: '#ec7211'
---


We have [seen previously]({% link _posts/2023-11-27-self-hosted-website.markdown %}) on how to host your public website from your local machine.

In this article we will see how to use [Terraform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template#network-interfaces) and
[AWS](https://aws.amazon.com/) to host your website. 

{% preview "https://www.terraform.io/use-cases/infrastructure-as-code" %}

We will do these incrementally

- Make a simple server
- Build a docker image, and push to ECR
- Use a firewall to allow traffic from certain ports
- Setup a simple server on an EC2 instance and deploy the image
- Manage EC2 instances with ECS, using launch templates
- Using a load-balancer and a vpc network instead of accessing public ip for ec2

<p>&nbsp;</p>

### AWS Free Tier

AWS Free Tier, allows you to run an ec2 instance for an year, 750 hours a month.

It allows to have a t2.micro or t3.micro machine, which basically describes how many cpus you can have. And support for EBS. 
The availability also depends on the region.

- ECS is always free,
- Auto Scaling Group which ECS can use to scale, is always free.
- Load balancing is free for 12 months or 750 hours. and _luck runs out slower_

We do however need to pay if we want to our services to access the internet, like serving a page, downlading packages, Lol _Jokes on capitalism_.

End of the day, pay your internet bill.

<p>&nbsp;</p>
### Pre-requisite

- AWS account and AWSCLI
- Terraform
- Docker
- Unix machine
- A running webserver to serve requests

<p>&nbsp;</p>

### Preparation

We are going to use a simple golang server for then example.I am not going to present a full fledged working code, just the `main.go`

```go
package main

import (
	"flag"
	"log"
	"net/http"
	"konoha/app/authentication"
	"konoha/app/bookdetails"
	"konoha/app/login"
	"konoha/conf"
	"konoha/db/dbconnector"
	"time"

	"github.com/gorilla/mux"
)

var cfg conf.Config

func main() {
	var envFile string
	flag.StringVar(&envFile, "e", "./conf/.env", "pass env file")

	flag.Parse()

	log.Println(envFile)
	cfg = conf.LoadConfig(envFile)

	log.SetFlags(log.LstdFlags | log.Llongfile)

	r := mux.NewRouter()
	srv := &http.Server{
		Handler:      r,
		Addr:         ":9090",
		WriteTimeout: 15 * time.Second,
		ReadTimeout:  15 * time.Second,
	}

	r.Use(JSONMiddleware)

	r.HandleFunc("/ping", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("pong"))
	})

	r.HandleFunc("/konoha/api/ping", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("pong"))
	})
	pgconn := dbconnector.NewPostgresConnector(cfg.SupabaseConfig.DBURL)

	r.HandleFunc(
		"/konoha/api/v1/login",
		login.LoginHandlerInject(cfg, &login.AppContext{Dbconn: pgconn}),
	).Methods("POST")

	authRouter.HandleFunc(
		"/konoha/api/books/all",
        bookdetails.BookDetailsFetcherInjector(cfg),
	).Methods("GET")

	log.Println("Listening to server on PORT 9090")
	log.Fatal(srv.ListenAndServe())
}

func JSONMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Add("Content-Type", "application/json")
		next.ServeHTTP(w, r)
	})
}

```

Now lets make a *docker image* from this.

```docker
FROM golang:1.21 as builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /opt/server cmd/server/main.go

FROM alpine:3.14

ENV ENV=prod

WORKDIR /opt/app
COPY --from=builder /opt/server /opt/app/server
COPY --from=builder /src/conf/.env /opt/app/conf/.env

RUN chmod +x "/opt/app/server"

EXPOSE 9090
CMD ["/opt/app/server"]
```

And build it with

```shell
docker build -t konoha-server:latest .
docker run --publish 9090:9090 konoha-server:latest
```

<p>&nbsp;</p>

### Setup AWSCLI

{% preview "https://docs.aws.amazon.com/streams/latest/dev/setting-up.html" %}

Before setting up `awscli`, we need to create an IAM role with `AdministratorAccess` policy.

- Goto IAM and Create User
- Choose both Programmatic access and AWS Management Console access.
- Choose attach policies directly and add `AdministratorAccess`
- Upon successfull creation, you will see a nnumber like `909***`, which is your AWS Account ID.
- Go to the user detail page `IAM > Users > {Your created user}, and `Create Access Key`

After completing this you should have the `AWS_ACCESS_KEY` and `AWS_SECRET` which you will use to configure the cli. Using

```shell
aws configure
```

Make sure to choose the proper region during configuring. [Here](https://www.techtarget.com/searchcloudcomputing/tutorial/Step-by-step-guide-on-how-to-create-an-IAM-user-in-AWS) is an
article with images.

<p>&nbsp;</p>

### Configure IAM roles

In the previous step we have seen configured a `Role` with admin access. But that's for our cli access. We need to create roles so that certain AWS services can
perform actions on our behalf with limited access. For example,

- pulling and pushing from ecr
- getting auth tokens for ecr login command
- creating and putting logs to log stream etc,

For now we will create two roles, one for the EC2 instance and the other for the ECS task later on. You can either create them with terraform, or cli or UI.

The two policies we need are:
- [AmazonECSTaskExecutionRolePolicy](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html)
- [AmazonEC2ContainerServiceforEC2Role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-awsmanpol.html)

I have created two roles manually with the aws cli. But it can be done with terraform while running the job.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```
_ecs_execution_role.json_

```shell
aws iam create-role \
      --role-name ecsInstanceRole  \
      --assume-role-policy-document file://./infrafiles/ecs_execution_role.json


aws iam attach-role-policy \
      --role-name ecsInstanceRole  \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role



aws iam create-role \
      --role-name ecsTaskExecutionRole \
      --assume-role-policy-document file://./infrafiles/ecs_execution_role.json

aws iam attach-role-policy \
      --role-name ecsTaskExecutionRole  \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```


<p>&nbsp;</p>

### Hosting your docker build

Next we are going to take the docker executable and host it in ECR so that we can pull it into our EC2 instance.

In order to do that, you need the url to push to. The nature of the url is documented [here](https://docs.aws.amazon.com/AmazonECR/latest/userguide/getting-started-cli.html). This script will come in handy.

{% preview "https://docs.aws.amazon.com/AmazonECR/latest/userguide/getting-started-cli.html" %}


```bash
#!/bin/bash
#
# Upload image to ecr
# requires AWS_ACCOUNT, AWS_REGION, VERSION
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

VERSION=$(git rev-parse --short HEAD)
DOCKER_BUILD_TAG="konoha-server:${VERSION}"

echo "Building docker image with tag $DOCKER_BUILD_TAG"

docker build --platform linux/amd64  -t "${DOCKER_BUILD_TAG}" .

docker tag "${DOCKER_BUILD_TAG}" "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${DOCKER_BUILD_TAG}"
docker push "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${DOCKER_BUILD_TAG}"
```

### Terraform to deploy

Before terraform, we need to be aware of __What is EC2__. Basically EC2 (technically ECC) provides you a mechanaism to boot up a machine of your choice
and then run applications inside it.

There are features build around it, like the ability to make an EC2 instance available in a particular zone/network, attach firewall rules, manage resources consumed etc.

{% preview "https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/concepts.html" %} 

A firewall in AWS is called a [Security Group](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html).


Now, as to __Terraform__, its a way to automate deployments. Like other tools ansible, chef etc. Its a new hot thing, comes with support for cloud providers,
maintains state and makes deployment scaling easier.


Our terraform project will have three files for time being:
- providers.tf
- aws_ecs.tf
- variables.tf

`terraform apply` would work on the files in the root directory as a whole, incase you want a seperate directory, you need to pass the root dir to `terraform apply` command.

First we need to choose an image to install 

First we need to specify the provider we need to use in a `providers.tf`.

```terraform
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}
```

And some variables:

```terraform
variable "DOCKER_IMAGE" {
  type = string
}

variable "AWS_ACCOUNT" {
  type = string
}

variable "ENVIRONMENT" {
  type = string
  default = "beta"
}
```

<p>&nbsp;</p>


### Chosing the right Image/OS for the EC2 instace.

AWS Free Tier only gives you a limited set of images in a given region which are allowed under free tier. And your level of frustration depends on finding the right image.

Some Linux images come with nothing but just an os, with no ecs-agent or docker installed. And some images maintained by community which come with basic things preinstalled. These are called `Amazon Linux Image` (AMI)s. 

Also, you need to be mindful of the underlying os architecture of your docker build and the target OS of the AMI. Docker images build with arm64 are best hosted on arm64 machines. Most AMI's support both versions of an image.

I have used the amazon-linux-20203 os. You can search for these `AMI` in your region from the AWS UI. Or you can use this command.

```shell
aws ssm get-parameters-by-path --path /aws/service/ecs/optimized-ami/amazon-linux-2023/ --region ${AWS_REGION}
```

{% preview "https://docs.aws.amazon.com/AmazonECS/latest/developerguide/retrieve-ecs-optimized_AMI.html" %}


### Basic building block

Let's create a basic ec2 instance running our docker image.

*aws_deploy.tf*

```terraform
provider "aws" {
  region = "ap-south-1"
}

resource "aws_instance" "konoha_server" {
  ami = "ami-027a0367928d05f3e"
  instance_type = "t2.micro"
  associate_public_ip_address = true

  iam_instance_profile = "ecsInstanceRole"

  user_data = base64encode(templatefile("${path.module}/templates/ecs/setup.sh", { IMAGE = var.DOCKER_IMAGE, AWS_ACCOUNT = var.AWS_ACCOUNT }))

  tags = {
      Name = "konoha-api-instance"
  }
}
```

ecs/setup.sh 

```shell
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
sudo docker pull "${IMAGE}"
sudo docker run -p 80:9090 -d "${IMAGE}"
```

<p>&nbsp;</p>

### Setup to facilitate SSH

*aws_deploy.tf*

```terraform
resource "aws_key_pair" "tf-key-pair" {
  key_name = "tf-key-pair"
  public_key = tls_private_key.rsa.public_key_openssh
}

resource "tls_private_key" "rsa" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "tf-key" {
  content  = tls_private_key.rsa.private_key_pem
  filename = "tf-key-pair.pem"
}
```

And we need to attach the aws_instance to the key. To do that, add a line to the `aws_instance` block.

```terraform

resource "aws_instance" "konoha_server" {
  key_name = "tf-key-pair"
}
```

<p>&nbsp;</p>

### Attach firewall

We need to allow access to certain inbound port and outbound port. For outbound we will now all allow traffic from the ec2 instances.

For inbound rules, we will allow traffic from ports: 80 (http), 443 (https), 22 (ssh) . We won't enable 9090, because our docker image is exposing on port 80 with `-p 80:9090`.

In AWS terms its called [Security Group](https://docs.aws.amazon.com/vpc/latest/userguide/security-group-rules.html) . You can find example implementation with [terraform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) 

<img src="{{ site.baseurl}}/img/security-group-overview.png" style="width: 100%"/>


_client's computer, connects to the vpc, via an internet gateway (in purple). the security group, firewalling the access_


*aws_deploy.tf*

```terraform

resource "aws_security_group" "demo_api_sg" {
  name = "DemoAPISg"

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    cidr_blocks     = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

```

Now, in this case, we will be using the default vpc. and add attach the security group to the `aws_instance` definition.

```terraform

resource "aws_instance" "konoha_server" {
  // add this line to the definition above.
  vpc_security_group_ids = [aws_security_group.konoha_api_sg.id]
}
```

We will also need to generate a ssh keys for us to login to the ec2 instance. 



This will generate you a ssh key, called `tf-key-pair.pem` which will allow you to login to the ec2 instance.


And you are ready for your first deploy __IaaC__ . 


Here is a small shell wrapper over `terraform` cli commands. Because we need to pass some `var` as environment variables.


```shell
#!/bin/bash
#
# Wrapper over terraform commands and helpers
#
#
function apply() {
  echo "aws account ${AWS_ACCOUNT} ${DOCKER_BUILD_TAG}"
  terraform init

  TF_VAR_AWS_ACCOUNT=${AWS_ACCOUNT} \
    TF_VAR_DOCKER_IMAGE="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${DOCKER_BUILD_TAG}" \
    terraform validate

  TF_VAR_AWS_ACCOUNT=${AWS_ACCOUNT} \
    TF_VAR_DOCKER_IMAGE="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${DOCKER_BUILD_TAG}" \
    terraform plan -out=tfplan

  TF_VAR_AWS_ACCOUNT=${AWS_ACCOUNT} \
    TF_VAR_DOCKER_IMAGE="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${DOCKER_BUILD_TAG}" \
    terraform apply "tfplan"
}

function destroy() {
  TF_VAR_AWS_ACCOUNT=${AWS_ACCOUNT} \
    TF_VAR_DOCKER_IMAGE="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${DOCKER_BUILD_TAG}" \
    terraform destroy
}


function show() {
  TF_VAR_AWS_ACCOUNT=${AWS_ACCOUNT} \
    TF_VAR_DOCKER_IMAGE="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${DOCKER_BUILD_TAG}" \
    terraform show
}

function output() {
  TF_VAR_AWS_ACCOUNT=${AWS_ACCOUNT} \
    TF_VAR_DOCKER_IMAGE="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${DOCKER_BUILD_TAG}" \
    terraform output
}

__ACTIONS__=":apply:show:destroy:"
ACTION="show"

usage() { echo "Usage: $0 [-a <show|apply|destroy>]" 1>&2; exit 1; }

while getopts ":a:" arg; do
  case "${arg}" in
    a)
      ACTION="${OPTARG}"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ ! "${__ACTIONS__}" =~ ":${ACTION}:" ]]; then
  echo "invalid actions"
  usage
  exit 1
fi

echo "Running terraform ${ACTION}"
if [[ "$ACTION" == "show" ]]; then
  show
elif [[ "$ACTION" == "apply" ]]; then
  apply
elif [[ "$ACTION" == "destroy" ]]; then
  destroy
elif [[ "$ACTION" == "output" ]]; then
  output
fi
```


```shell
$ AWS_REGION=${AWS_REGION} AWS_ACCOUNT=${AWS_ACCOUNT} DOCKER_BUILD_TAG=${DOCKER_BUILD_TAG} bash scripts/tcl.sh -a apply
```

where `DOCKER_BUILD_TAG=konoha-server:latest` in our case. We can chose something like `konoha-server:$(git commit -1 --oneline | cut -d' ' -f1)` or even manual versioning with `git tag` works too.

<p>&nbsp;</p>

### How to access

There are two ways you can access this.

__First__ from your [AWS ui console](https://console.aws.amazon.com/), search for `EC2`> `Instances` > `Public DNS` or `Public IP` should be there, on the right hand side.

__Second__ programatically using `terraform`. You need to create an output.tf file, with an output resource block.

_output.tf_

```terraform
output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.konoha_server.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.konoha_server.public_ip
}
```

`aws_instance` and `konoha_server` refers to the `resource "aws_instance" "konoha_server" {}` block, above. and run

```shell
$ AWS_REGION=${AWS_REGION} AWS_ACCOUNT=${AWS_ACCOUNT} DOCKER_BUILD_TAG=${DOCKER_BUILD_TAG} bash scripts/tcl.sh -a output
```

Incase you have this file already present, `terraform apply` should show you the output in the end without having to call `terraform output` in the end.


<p>&nbsp;</p>

### Next steps

Next post we will discuss how to use an create an `ECS cluster` with `AutoScalling Groups` to launch `EC2 instances` within the cluster. Attach the cluster to a `vpc` and `serve internet traffic` with a `Loadbalancer`.


