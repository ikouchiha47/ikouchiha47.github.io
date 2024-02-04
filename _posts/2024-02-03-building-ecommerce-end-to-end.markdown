---
layout: post
title: "Building an ecommerce website end to end"
subtitle: "career breaks doesn't mean end of work"
description: "Going for a productive career break"
date: 2024-01-11 00:00:00
background_color: '#da46ff'
---

## From Career Break to E-commerce Product: Relearning Rails and Build ecommerce platform

Taking a career break can be daunting, but I used mine to embark on an ambitious project: building an end-to-end e-commerce website from scratch. Fueled by the memory of Rails 4, I dove in headfirst, only to realize the landscape had shifted dramatically with the arrival of Rails 7. 

### Rails 7: A Crash Course in the New Frontier

My initial excitement turned into nervous trepidation. Where do I even begin? Documentation became my bible, and countless hours were spent deciphering new patterns and paradigms. The biggest hurdle? **js.erb**. This new way of working with JavaScript felt alien, demanding a complete rethink of my front-end approach.

Gone were the days of fat models and skinny controllers. Rails 7 embraced a more modular approach, separating concerns and encouraging component-based development. Handling JavaScript requests in controllers meant understanding Stimulus Reflex and Turbo, paradigms that streamlined communication between front-end and back-end. It was a steep learning curve, but with perseverance, I scaled it, embracing the modularity and efficiency js.erb offered.


### Handling JavaScript Requests: A Tale of Two Rails

**Rails 4: The UJS Era**

In Rails 4, handling JavaScript requests was often a blend of Unobtrusive JavaScript (UJS) and manual DOM manipulation:

**Controller Code:**

```ruby
class ProductsController < ApplicationController
  def add_to_cart
    @product = Product.find(params[:id])
    # ... cart logic ...
    respond_to do |format|
      format.html { redirect_to cart_path }
      format.js   # Renders 'add_to_cart.js.erb'
    end
  end
end
```

**View Template (add_to_cart.js.erb):**

```javascript
// Update cart count using UJS
$('.cart-count').text('<%= current_cart.item_count %>');
// Show a success message
$('#flash-messages').html('<%= j render 'shared/flash_messages' %>');
```

**Rails 7: Embracing Stimulus Reflex and Turbo**

Rails 7 takes a more streamlined approach, leveraging Stimulus Reflex and Turbo:

**Controller Code:**

```ruby
class ProductsController < ApplicationController
  def add_to_cart
    @product = Product.find(params[:id])
    # ... cart logic ...
    head :ok  # Signal success to Turbo
  end
end
```

**Stimulus Controller:**

```javascript
// app/javascript/controllers/add_to_cart_controller.js
import { Controller } from "stimulus";
import { Reflex } from "stimulus_reflex";

export default class extends Controller {
  static targets = ['count', 'flash'];

  add() {
    Reflex.fromElement(this.element).addProductToCart();
  }

  afterReflex() {
    this.countTarget.textContent = this.data.get('cart-count');
    this.flashTarget.innerHTML = this.data.get('flash-messages');
  }
}
```

### Stimulus and Turbo: Streamlining Interactions in Rails 7

In Rails 7, two key libraries, Stimulus and Turbo, work together to create faster, more dynamic, and engaging web applications. Let's delve into their individual roles and how they contribute to Rails 7's efficiency:

**Stimulus: Simplifying Interactivity**

- **What it is:** A lightweight JavaScript library promoting modularity and separation of concerns.
- **What it does:**
    - Binds JavaScript behavior to specific HTML elements using data attributes.
    - Creates reusable Stimulus controllers that manage specific UI interactions.
    - Handles user events like clicks, forms, and DOM changes.
    - Communicates with the server using Stimulus Reflex (covered later).
- **Benefits:**
    - Clean and organized code for JavaScript logic.
    - Easier testing and maintenance of interactive elements.
    - Encourages component-based development.

**Turbo: Boosting Navigation Performance**

- **What it is:** A JavaScript library facilitating seamless page updates without full reloads.
- **What it does:**
    - Intercepts link clicks and form submissions to prevent default behavior.
    - Makes partial requests to the server for specific HTML updates (Turbo Frames).
    - Updates only the necessary parts of the DOM, preserving state and avoiding full page reloads.
    - Integrates with Stimulus Reflex for server-side actions and data fetching.
- **Benefits:**
    - Significantly faster page transitions and user interactions.
    - Improved user experience, making the app feel more responsive.
    - Reduced page weight and bandwidth usage.

**Stimulus Reflex: Bridging the Gap**

- **What it is:** An extension of Stimulus that facilitates communication between client-side interactions and server-side actions.
- **What it does:**
    - Stimulus controllers can trigger Reflex actions on the server.
    - Reflex actions handle server-side logic, update data, and return partial HTML responses.
    - Turbo then integrates the updated HTML into the page seamlessly.
- **Benefits:**
    - Efficient server-side data fetching and updates triggered by user interactions.
    - Enables real-time updates and dynamic interactions without full page reloads.
    - Simplifies complex interactions by separating concerns between client and server.


If you're starting a new Rails 7 project, embracing Stimulus and Turbo is highly recommended. They offer a modern and efficient approach to building interactive and performant web applications, improving development experience, however weird.


## Beyond Code: Design Dilemmas and Brutal Beauty

But an e-commerce website isn't just code; it's an experience. Design became my next frontier. Armed with "Non-Designer's Design Book" and countless website reviews, I delved into the world of aesthetics. Trends like brutalism intrigued me, with its emphasis on raw functionality and bold typography. I experimented with this aesthetic, creating a clean and efficient layout that prioritized product visibility. The trick to making things look good is grouping and balancing. 

Animation, too, captured my imagination. [GSAP](https://gsap.com/resources/get-started/) specifically, Subtle product rotations on hover, smooth product filtering transitions – these small touches added a layer of polish and delight to the user experience.

But for an `MVP` this was unnecessary. I did waste some time on this. Also you dont need a fuckton of animations.

Choosing a **color scheme** is a different dilemma all together.



**The Power of CSS Grids and Flexbox**

My design journey also involved getting a grasp on:
- How to design 
- Understanding how to position elements with CSS Grids and Flexbox. Because they are one of the best things to happen in css.

Flexbox offered me the flexibility to arrange elements horizontally or vertically, adjusting their alignment and distribution. CSS Grids, on the other hand, provided a structured approach, allowing me to create complex layouts with rows, columns, and gaps.

** For the most parts, Flexbox works just fine **

### Overcoming Common Hurdles:

Initially, I encountered the same challenges many face when learning these tools:

- Understanding the syntax and properties: Both Flexbox and Grids have their unique syntax and properties, requiring practice and experimentation to grasp fully.
- Visualizing the layout: Thinking spatially and translating that vision into code takes time and experience.

However, I binged on website reviews, [dribble](https://dribbble.com), [Awwwards](https://www.awwwards.com), [Behance](https://www.behance.net). For most part the
website felt empty, so I had to generate some mockups using [mockey](https://mockey.ai/), and start filling out some products.

**Mobile-First: A Responsive Mindset**

I adopted a mobile-first approach, starting with the smallest screens and gradually adapting the layout for larger devices. This had several benefits:

- Prioritizing mobile users: The majority of website traffic comes from mobile devices, so optimizing for smaller screens is crucial.
- Smaller changes for larger screens: Starting with a well-structured mobile layout simplifies adjustments for larger screens, often just requiring tweaks to grid and flexbox properties.
- Avoiding horizontal eye fatigue: On large screens, setting some fixed widths for content ensures users don't have to make long horizontal eye movements, improving readability and navigation.

**A Responsive Blend: Grids and Flexbox in Harmony**

The website didn't rely solely on one tool. I strategically combined Grids and Flexbox depending on the screen size and layout requirements. 
Flexbox proved invaluable for responsive headers, product carousels, and user interfaces, while Grids helped structure product listings and complex page layouts.


#### The Rise of the PowerPoint Presentation Website: A Rant

However, my exploration of website design wasn't all sunshine and rainbows. A concerning trend emerged: the prevalence of websites resembling glorified PowerPoint presentations. Endless horizontal scrolling, jarring animations, and intrusive pop-ups became commonplace, prioritizing aesthetics over usability. While these elements might grab attention for a fleeting moment, they often leave behind a trail of frustration and accessibility issues.

The UX Nightmare:

Imagine navigating a website that bombards you with horizontal scroll after horizontal scroll, each slide filled with text-heavy paragraphs and flashy animations. It's a recipe for nausea and annoyance, especially on mobile devices with limited screen real estate. Not only is it tedious to navigate, but it also disproportionately impacts users with slower internet connections or less powerful devices, potentially leading to browser crashes and a complete barrier to accessing information.

**Accessibility: Beyond "Knock, Knock, Your Items Are Waiting For You"**

Accessibility often takes a backseat in this pursuit of visual spectacle. Websites crammed with animation and lacking proper semantic structure become impassable for users with disabilities, particularly those relying on screen readers. Imagine being a blind person trying to shop online, with your screen reader announcing "knock, knock, your items are waiting for you" without any clear context or navigation cues. It's not just frustrating, it's exclusionary.

`A Call for Balance:`

I'm not advocating for websites to be devoid of all design elements. Creativity and visual appeal have their place. But it's crucial to strike a balance, prioritizing user experience and accessibility above all else. Websites should be clear, concise, and navigable, ensuring everyone has an equal opportunity to access information and complete tasks.


#### Key points to consider

**Visual Hierarchy & Readability:**

- Color Contrast: Ensure sufficient contrast between text and background for optimal readability (WCAG guidelines are a great resource).
- Typography: Choose clear, legible fonts suitable for different screen sizes and avoid excessive font variations. Headings, subheadings, and body text should have distinct hierarchy.
- Balance & White Space: Avoid clutter! Create visual breathing room with balanced use of elements and negative space.
- Grouping & Proximity: Group related elements visually to enhance understanding and information flow.

**User Interaction & Usability:**

- Clarity & Actionable Items: Use clear, concise language for labels, buttons, and instructions. Make CTAs (Call to Actions) stand out with contrasting colors and shapes.
- Forms & Interactions: Design intuitive forms with clear labels, error messages, and consistent interaction patterns. Prioritize user flow and minimize navigation complexity.
- Responsiveness: Adapt your design to different screen sizes and devices, ensuring seamless use across platforms.

Additionally:

- Color Psychology: Understand how colors evoke emotions and use them strategically to guide user experience.
- Imagery & Icons: Use high-quality, relevant images and icons that enhance understanding and brand identity.
- Testing & Feedback: Get user feedback early and iterate on your design based on their experiences.


Thanks to the **Non Designers Design Handbook** and *Kevin Powell* and *Flux Academy* and other blogs and youtubes.


## Building the Infrastructure: A Network Odyssey

The journey didn't end at the storefront. I had to build the infrastructure: a robust network that could handle product uploads, multi-device testing, and everything in between. This was uncharted territory for me, but the thirst for knowledge propelled me forward.

IPv4 vs. IPv6: A Balancing Act

My initial foray into networking began with understanding the intricacies of IP addresses. IPv4, the familiar friend, was slowly reaching its capacity. IPv6, the promising newcomer, beckoned with its vast address space. I learned that most modern devices, like my iPhone, could utilize both. Excitement filled me as I configured my DNS provider to point to my public IPv6 address – success! My website proudly served content on my iPhone.

But then came the reality check. Android devices, with their diverse configurations, presented a different story. My IPv6 dream crumbled. Undeterred, I explored solutions.

**No-IP.com: A Detour with Static IPs**

No-IP.com, offering static IP addresses, seemed like a potential answer. It would act as a bridge between my dynamic IPv6 and the outside world, ensuring consistent accessibility. However, a nagging feeling persisted – this was an unnecessary complication.

**ZeroTier: The VPN Savior**

The answer arrived in the form of ZeroTier. This clever software allowed me to create a private network, connecting my laptop and cloud server regardless of their physical locations. No need for complex configurations or static IPs. With ZeroTier, my machines shared virtual IP addresses within the network, enabling seamless communication.

**Socat: The Traffic Conductor**

Socat, a versatile networking tool, became my next companion. It efficiently redirected traffic between my machines, ensuring smooth data flow within the ZeroTier network.


#### Security First: Fortifying the Network

Security was paramount. I meticulously configured firewall rules, locking down all ports except the essential 22 (SSH) and 443 (HTTPS). This created a secure environment, protecting my network from unauthorized access.


#### Nginx: The Gateway and Guardian

Finally, Nginx, the powerful web server, took center stage. It acted as the gateway, proxying traffic to my Rails application. Additionally, it handled SSL validation and encryption, ensuring secure communication between my website and visitors.


## Challenges Conquered, Triumph Earned

This network odyssey, though intricate, proved invaluable. I not only built a secure and scalable infrastructure but also broadened my technical expertise. From deciphering IP protocols to mastering network tools, the journey empowered me to face any future challenge with confidence.

Remember, this is just a glimpse of my experience. What challenges did you face in building your own projects? Share your stories in the comments below!

Looking back, the project was an emotional rollercoaster. The learning curve was steep, the road fraught with detours, but the sense of accomplishment is unparalleled. I not only built an e-commerce website but also transformed myself. Now, armed with Rails 7 expertise, design sensibilities, and infrastructure know-how, I'm ready to tackle any development challenge that comes my way.

**The Heartbreak of Payment Integrations**

Just as I felt I was getting the hang of things, another blow: Razorpay, my chosen payment gateway, stopped onboarding new merchants. Unfortunately payments is still pending.


## What's next

There are a couple of things that need to be done.

*First*, I need to write `IaC` to be able to host this easily on any cloud provider. Hosting it on my laptop was always a fun activity.
One of the main challenges here, is I have to backup system, it's *one laptop* and a *single point of failure*.
It is also a hassle to keep the security certificates and system libraries updated.

*Second*, I need to build some admin UI around this. Some boring ass CSV parser to upload products. And need to actually start sending emails
for password reset, :D
People need to be able to at least generate some bills. This also means one needs to be able to change the company name and some
other text, from configuration. Atleast for an MVP.

*Third*, my own storefront hasn't come to life yet, but I can maybe sell this product as a bundle to small scale businesses, and provide support
to them as a SaaS product, if needed.

`Thank you.`
