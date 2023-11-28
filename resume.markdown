---
layout: page
title: Resume
background_color: '#000'
permalink: /resume/
---

## # Amitava Ghosh
[amitava.dev@proton.me](mailto:amitava.dev@proton.me) | [@ikouchiha47](https://github.com/ikouchiha47) | [linkedin.com/in/amitavaag](http://www.linkedin.com/in/amitavaag)

Bangalore, India

-------


## PROFESSIONAL SUMMARY

I am mostly a platform engineer, building backend systems and a bit of frontend, for around 6 years. I have worked successfully across multiple tech stacks. I have a very good understanding of event based systems. I like to experiment with new technologies. 

I work best as an *Individual Contributor*, but I have always worked in tandem with team members, learning and helping others.

I am looking for opportunities to work on scalable systems with good team members to learn and contribute.

For work I have a strong passion for reducing stress on people and systems.

<p>&nbsp;</p>

## EXPERIENCE
- Experienced in code reviews, deployment planning, and building metric monitoring systems and performance enhancement. 
- Delivering scalable software which are easy to contribute to, have an ecosystem around them for better integration and obviously create less chances of introducing bugs


<p>&nbsp;</p>

## SKILLS
- Languages: Golang, Python, Javascript, Bash, Rails, Lua. etc (anything except Java)
- MQ: Kafka, SQS
- Storage: Mysql, Redis, Postgresql, DynamoDB
- AWS, Terraform, Kong(nginx), Docker, Unix & Networking Tools.
- Some knowledge of kubernetes
- Api design, Api security, System Design.

_i like learning new languages_ 

<p>&nbsp;</p>

## WORK EXPERIENCE
<p>&nbsp;</p>

### Sequoia Consulting - Bangalore, _India 2020-2023_

Mostly worked on platform enginnering, architecting systems, building tools and libraries.
Determining performance bottleneck, by benchmarking and profiling and 
<p>&nbsp;</p>

#### Senior Software Engineer

- Lead code reviews and orchestrate deployments for multiple services in the platform team.
- Added support to logging library to handle PII data scrambling.
- Solved a couple of SSO authentication issues, which helped retain clients.
- Solved and helped other teams to migrate client's file to encrypted storage and planned a backward compatible release
  - As a part of the above step, also build a url shortner service to server encrypted files and figure cache invalidation policy
  - Build executable to be used by other languages due to a limitation of AWS library, and helped others integrate it
  - Collaborated with the front-end teams to fixed CORS headers and helped with the file downlaod with proper name 
- Developed a robust metric monitoring system from scratch using Golang and Redis as the data store, It did
help us resolve an issue with notification service in proper time limit. 
<p>&nbsp;</p>

#### SDE-II

- Build and maintain notification service to deliver `emails` and `push`. It helped track delievery, prevent re-delivery. 
- Analyzing and imporving db queries and system architecture to prevent db lockup along with datadog APM integration
- Build and maintain the golang sdk for the organisation
- Establish proper logging practices,introduced tracing api calls and time taken. This helped debug slow user logins due to problems in other system.
- Worked with Devops on fixing server-redis connection problems using strace. This eventually would enable people to use redis and cache user info.
- Integrating logs using opensearch and a makeshift tracing library to trace api calls across services
- Introducing migration standards and instrumentaion of existing codebases
- Introduced caching and removing cross db connection and other fixing other problems with system design

<p>&nbsp;</p>
---

### Gojek - Bangalore, _India 2016 - 2020_

Worked across more than **5 projects.**

- **Go-fresh** , a platform for merchants and outlets to buy and sell raw materials
- **Mart,** a marketplace to order products from malls in Indonesia
- **Global Search,** to search across three major sub-apps of Gojek
- **Gatekeeper,** for authorization and authentication of requests
- **Customer Owner, Authentication &amp; OTP service** , for one-stop authentication of customers, drivers, and merchants. And sending OTP to users.
<p>&nbsp;</p>

**Work Involved**

- Centralizing **authentication system** for customer, driver and merchant auth.
- Splitting into **multiple microservices** to handle **OTP and Notifications**
- Adding **rate limiters** that **helped in reduction of frauds against customers.**
- Building **notification systems** and integrating with multiple providers, **reducing organizational costs**.
- Setting up **kong (API Gateway)** for the entire Gojek for **authentication of requests** beforehand
- Coordinating with teams to centralize the service, to decentralize maintenance and **enabling easy security review**.
- **Analyzing TCP dumps** for properly configuring timeouts and keepalives, for the above, and **establishing a template** for configuration of apis for the same.
- **Optimizing&#39; API for CSV upload** and record creation with **4 million records** every **3-4 hours.**

- Using **Kafka** to handle **high amounts of load** , **state machines** to ensure **casualty** and **ordering** of events in distributed systems
- Using **caching** to speed up systems and reduce database loads.
- Building UI to upload static data for product search
- Setting up metrics and alerting for better visibility of systems and their failures

**Personal Projects:**

- Building a slack bot for getting OTP, language translation, getting IP address of boxes.
- Building a unified meta CLI tool for, which involved box creation.

**Also,** have been in War Rooms , during production issues, splitting requests at Haproxy, helping others debugging issues, warming up Redis cache etc.

<p>&nbsp;</p>
---


### Leftshift - Pune,  _India 08/2016 - 09/2016_

Worked in **1 project.**

-  **Sequoia::Hack** , an app for Sequoia Capital&#39;s hackathon

_This company was later acquired by Gojek_

<p>&nbsp;</p>

**Work Involved**

- Writing tests with mocha and jasmine runner for the backend
<p>&nbsp;</p>

---


**Kreeti Technologies - Kolkata** _, India 2014-2016_

Worked across **4 projects.**

- **Memento,** a social networking app
- **SMarketplace,** a marketplace for Retailers and CPG&#39;s for hosting promotions and selling products
- **Merayog** , a matrimony platform
<p>&nbsp;</p>

**Work Involved**

- Setup of the entire application stack of memento, database design, frontend tool selection and automation
- Implementation of login and account creation for CPG and Retailer, authentication, and authorization.
- Photo upload using s3 and ImageMagick for image formatting
- Implementing a commenting feature on the promotions page for communication between multiple parties
- Email-based weekly and daily reminder of promotions
- Rebuilding the internal payslip generation internal application in a different language stack

<p>&nbsp;</p>

---


## EDUCATION

**Bachelors in Electronics and Communication**. 2010-2014

Dr. Sudhir Chandra Sur Degree Engineering College, West Bengal, India

<p>&nbsp;</p>

---

### Personal Projects
<p>&nbsp;</p>

- A simple chat application to show users who joined the LeftShift network using id/pass. Users could share files and texts. Messages were sent via TCP and user join and left events were done using UDP custom format.
- Other stuff [@amitavaghosh1](https://github.com/amitavaghosh1)| [go-gorm/dbresolver](github.com/go-gorm-v1/dbresolver)
- StackOverflow:  https://stackoverflow.com/users/1503615/argentum47

