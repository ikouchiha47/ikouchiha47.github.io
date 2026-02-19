---
active: true
layout: post
title: "Automate deployment with CI/CD"
subtitle: "Simple setup using gitlab, aws and terraform"
description: "Setting up ci/cd on gitlab and automate deployment with terraform"
date: 2024-01-11 00:00:00
background_color: '#da46ff'
---

# Streamlining Infrastructure Management with IaC

In the world of cloud computing, managing infrastructure can be a complex and time-consuming task. Manual configuration and provisioning can lead to inconsistencies, errors, and delays. Infrastructure as Code (IaC) provides a solution by allowing you to define your infrastructure using code, enabling version control, automated deployments, and consistent environments.

Our IaC Journey with Terraform

We recently embarked on an IaC journey to streamline our deployment processes for multiple services within the Newsaggregator ecosystem. Here's a breakdown of our approach:

## Repositories for Code and Infrastructure:

- `app-server`: Houses the server code.
- `app-base-infra`: Contains code for setting up IAM, networking, and other foundational infrastructure.
- `app-metals-infra`: Manages services using ASGs, EC2 instances, S3, Lambda, and more.

## Terraform for Infrastructure Definition:

We chose [Terraform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template#network-interfaces) as our IaC tool for its ease of use, comprehensive AWS support, and strong community. Terraform scripts define our infrastructure components, including:

- IAM policies, roles, and users
- VPCs, subnets, and security groups
- Route53 records
- ACM certificates
- ECS tasks with autoscaling groups and load balancers
- S3 buckets
- Lambda functions

## GitLab CI for Automated Pipelines:

GitLab CI orchestrates our pipeline processes:

- app-server CI pipeline:
  - Builds Docker images
  - Tags images with commit hashes
  - Uploads images to ECR
  - Updates version numbers in SSM parameters
- app-base-infra CD pipeline:
  - Sets up IAM, networking, and other foundational infrastructure
- app-metals-infra CD pipeline:
`-Deploys ECS tasks, ASGs, load balancers and connects to cluster

Secure AWS Credentials:

- AWS access keys and secrets are stored as pipeline variables, ensuring security.

For gitlab, you can chose the *Protected* and *Mask* checkboxes, to make those variables available
only in *protected* branches. (Check Branch protection rules in your gitlab ci setting)


## Benefits of Our IaC Implementation:

- Automation: Eliminates manual configuration and provisioning.
- Consistency: Ensures identical environments across deployments.
- Version control: Tracks changes and enables rollbacks.
- Auditability: Provides clear history of infrastructure changes.
- Scalability: Facilitates easy infrastructure expansion.


Next Steps:

- Pipeline YAML sharing: We'll share our pipeline YAML configurations for transparency and collaboration.
- ChatGPT integration: We'll continue exploring ChatGPT's potential for further automating policy creation and other tasks.


### `app-server` IaaC setup

For our `app-server/.gitlab-ci.yaml`,these are the steps we take:
- create iam role with access to `push pull images from ecr` and `ssm:GetParameters`, `ssm:PutParameter`
- create the image from our `Dockerfile`
- The docker `tag` is of the format `${APP_NAME}:${CI_COMMIT_SHORT_SHA}`.
- push it into the `ECR`. 
- update the `SSM Param` with the `docker tag` 

The `SSM Param` is of the format `/${ENVIRONMENT}/${APP_NAME}/apiserver/version`

CI variables to set:
- AWS_DEFAULT_REGION
- AWS_ACCOUNT
- AWS_ACCESS_KEY_ID
- AWS_SECRET_ACCESS_KEY


`.gitlab-ci.yaml`

```yaml

variables:
  DOCKER_REGISTRY: ${AWS_ACCOUNT}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
  DOCKER_APP_TAG: ${APP_NAME}:${CI_COMMIT_SHA:0:6} 
  DOCKER_HOST: tcp://docker:2375
  APP_NAME: talon-server

publish prod:
  variables:
    ENVIRONMENT: prod
  rules:
    - if: '$CI_COMMIT_REF_NAME == "master"'
  image:
    name: amazon/aws-cli:2.15.15
    entrypoint: [""]
  services:
    - docker:dind
  before_script:
    - amazon-linux-extras install docker
    - aws --version
    - docker --version
  script:
    - echo ${AWS_PROFILE}
    - echo ${AWS_DEFAULT_REGION}
    - echo $CI_COMMIT_SHORT_SHA
    - aws configure set aws_access_key_id $AWS_ACCESS_KEY_ID
    - aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
    - aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin "${AWS_ACCOUNT}.dkr.${AWS_DEFAULT_REGION}.amazonaws.com"
    - docker build --platform linux/amd64  -t "talon-server:$CI_COMMIT_SHORT_SHA" .
    - docker tag "${APP_NAME}:$CI_COMMIT_SHORT_SHA" "${AWS_ACCOUNT}.dkr.ecr.ap-south-1.amazonaws.com/talon-server:$CI_COMMIT_SHORT_SHA"
    - docker push "${AWS_ACCOUNT}.dkr.ecr.ap-south-1.amazonaws.com/${APP_NAME}:$CI_COMMIT_SHORT_SHA"
    - aws ssm put-parameter --name "/${ENVIRONMENT}/${APP_NAME}/apiserver/version" --value "${APP_NAME}:${CI_COMMIT_SHORT_SHA}" --type String --overwrite

```

The Policy for Gitlab looks like:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr:GetAuthorizationToken",
                "ecr:GetDownloadUrlForLayer",
                "ecr:DescribeRepositories",
                "ecr:ListImages",
                "ecr:DescribeImages",
                "ecr:ListTagsForResource",
                "ecr:DescribeImageScanFindings",
                "ecr:PutImage",
                "ssm:GetParameters",
                "ssm:PutParameter",
            ],
            "Resource": "*"
        }
    ]
}
```

This `SSM Param` allows the `CD` pipeline to determine which image to deploy. We are going to see later.


For the Networking setup and creating IAM roles for ECS to run our sever, I have decided to use a separate repository. In order to run our
terraform scripts, we need to be able to store the `terraform states` to s3. So we need to create a `bucket` in `S3`.

### `app-base-infra` for core setup

> A word about the setup. Presently in terraform, a `hcl` file is used to generate the backend config.
> 

We follow the same way to setup the `CI` variables.

`.gitlab-ci.yaml`

```yaml
stages:
  - validate
  - deploy
  - destroy

.template:
  image:
    name: hashicorp/terraform:1.7.1
    entrypoint: [""]
  before_script:
    - apk add --no-cache bash py-pip
    - python3 -m venv .venv
    - source .venv/bin/activate
    - pip install --upgrade pip awscli
    - aws configure set aws_access_key_id $AWS_ACCESS_KEY_ID
    - aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
    - export TF_VAR_AWS_ACCOUNT=${AWS_ACCOUNT}
    - export TF_VAR_AWS_REGION=${AWS_DEFAULT_REGION}
    - export TF_VAR_AWS_PROFILE=${AWS_DEFAULT_PROFILE}
    - export AWS_PROFILE=${AWS_DEFAULT_PROFILE}


validate infra:
  extends: .template
  stage: validate
  script:
    - export TF_VAR_APP_NAME=talon-server
    - export TF_VAR_PARAM_PREFIX=talon/apiserver
    - export TF_VAR_ENVIRONMENT=prod
    - terraform init -backend-config=./infra.hcl
    - terraform validate
  when: manual


create infra:
  extends: .template
  stage: apply
  script:
    - export TF_VAR_APP_NAME=talon-server
    - export TF_VAR_PARAM_PREFIX=talon/apiserver
    - export TF_VAR_ENVIRONMENT=prod
    - export AWS_PROFILE=${AWS_DEFAULT_PROFILE}
    - terraform plan -out=infra.plan
    - terraform apply -auto-approve infra.tfplan
  when: manual


destroy infra:
  extends: .template
  stage: destroy
  script:
    - export TF_VAR_APP_NAME=talon-server
    - export TF_VAR_PARAM_PREFIX=talon/apiserver
    - export TF_VAR_ENVIRONMENT=prod
    - terraform init -backend-config=./infra.hcl
    - terraform destroy -auto-approve
  when: manual
```

Here, I have made a few considerations.

`First`, generally in most blogs, the `validate & plan` are in one stage, storing the `terraform plan` file in artifcat or cache in gitlab.
This causes a security concern, because the `plan` file is not like an `ansible vault`, its not encrypted. So, I have separated the stages.
Its, `validate`, followed by `plan & apply`.

`Second`, for multiple stages, the `TF_VAR_ENVIRONMENT` needs to changes, and we can add another bunch of stages. For multiple applications.
There would be more such entries.

`Third`, Presently, the `infra.hcl` file has static values, but there is a workaround to make this dynamic using
environment variables, or `TF_VAR` variables or using a bash script to dynamically populate the hcl file.


This kind of begs the question of what happens, when the number of microservices increases.
> I will come back to this later.


### `app-metals-infra` for ecs, ags, lambda, rds etc.

The setup is exactly same as above. Except here, we follow a directory for each kind of deployment. Presently, the `services` directory will
host the IaaC code for running all `EC2` or `FARGET` backed instances/deployments.

This is like a `Monorepo` with sub-directories.

`.gitlab-ci.yaml` looks like this:

```yaml
stages:
  - validate
  - deploy
  - destroy

.template:
  image:
    name: hashicorp/terraform:1.7.1
    entrypoint: [""]
  before_script:
    - apk add --no-cache bash py-pip
    - python3 -m venv .venv
    - source .venv/bin/activate
    - pip install --upgrade pip awscli
    - aws configure set aws_access_key_id $AWS_ACCESS_KEY_ID
    - aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
    - export TF_VAR_AWS_ACCOUNT=${AWS_ACCOUNT}
    - export TF_VAR_AWS_REGION=${AWS_DEFAULT_REGION}
    - export TF_VAR_AWS_PROFILE=${AWS_DEFAULT_PROFILE}


validate:
  extends: .template
  stage: validate
  script:
    - export TF_VAR_APP_NAME=talon-server
    - export TF_VAR_PARAM_PREFIX=talon/apiserver
    - export TF_VAR_ENVIRONMENT=prod
    - cd services
    - terraform init -backend-config=./talon.hcl
    - terraform validate

deploy talon server:
  extends: .template
  stage: deploy
  script:
    - export TF_VAR_APP_NAME=talon-server
    - export TF_VAR_PARAM_PREFIX=talon/apiserver
    - export TF_VAR_ENVIRONMENT=prod
    - cd services
    - terraform init -backend-config=./talon.hcl
    - terraform plan -out=talon.tfplan
    - terraform apply -auto-approve talon.tfplan
  when: manual

destroy talon sever:
  extends: .template
  stage: destroy
  variables:
    TF_ROOT: services
  script:
    - export TF_VAR_APP_NAME=talon-server
    - export TF_VAR_PARAM_PREFIX=talon/apiserver
    - export TF_VAR_ENVIRONMENT=prod
    - cd services
    - terraform init -backend-config=./talon.hcl
    - terraform destroy -auto-approve
  when: manual


```

The `hcl` config files looks like this:

```hcl
bucket = "app-tfstates"
key    = "prod/app/infra/terraform.tfstate"
region = "ap-south-1"
```

## User Role Creation with ChatGPT:

In order to execute all these commands, we need proper `Roles` setup. Now we could do this, by I don't know, "reading".

But why do that, when we can just __crash and burn baby__. I've streamlined user creation with ChatGPT:

- Create a user with basic permissions.
- Run the pipeline and capture access-related error messages.
- Feed those messages to ChatGPT, which automatically generates the required inline JSON policy.

The list is quite big, you can figure that out on your own.


## Bonus

Here is a bonus script, for your local development, a wrapper around `terraform` cli, so that you don't need to export `TF_VAR`s.

```bash
#!/bin/bash
# This is a wrapper around terraform to run commands with
# project specific config
#
# USAGE: to use this, first call
# source ./scripts/terrawrapper.sh load-env <env-file>
# ./scripts/terrwrapper <terraform commands>
#
export AWS_PROFILE="app"

function set_envfile() {
  if [[ -z "$1" ]]; then
    echo "env file name not provided"
  fi

  echo "$1"
  export _TF_ENVFILE="$1"
}

function aws_account_id() {
  if [[ ! -z "${AWS_ACCOUNT_ID}" ]]; then
    echo "${AWS_ACCOUNT_ID} aws account id already set"
  else
    value=$(aws sts \
      get-caller-identity \
      --query "Account" \
      --output text \
      --profile="${AWS_PROFILE}"\
    )
        export AWS_ACCOUNT_ID="${value}"
  fi
}

function load_env() {
  file="${_TF_ENVFILE}"

  if [[ ! -f "$file" ]]; then
    echo "_TF_ENVFILE variable needs to be set"
    exit 1
  fi

  # echo "laoding from $file"

  declare -a env_vars

  while IFS= read -r line; do
    exported_var=$(echo "$line" | envsubst)
    # echo "Exported Variable: $exported_var"
    env_vars+=("$exported_var")
  done < <(grep -v '^#' "$file")

  export "${env_vars[@]}"
  
  # echo "profile $TF_VAR_AWS_PROFILE"
  # echo "app name $TF_VAR_APP_NAME" 
  # echo "env values exported"
}

if [[ "$1" == "load-env" ]]; then
  echo "setting env file"
  set_envfile "$2"
  echo "ENVFILE set to ${_TF_ENVFILE}"
elif [[ "$1" == "get-env" ]]; then
  echo "ENVFILE set to ${_TF_ENVFILE}"
else
  aws_account_id
  load_env

  if [[ -z "$TF_VAR_AWS_ACCOUNT" || -z "$TF_VAR_APP_NAME" ]]; then
      echo "env values not exported"
      exit 1
  fi

  terraform "$@"
fi
```


## Backword

IaC has proven to be a valuable tool for streamlining our deployment processes and improving infrastructure management. I'm excited to continue refining our approach and sharing our experiences with the community.


`Thank you.`
