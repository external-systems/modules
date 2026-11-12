<!-- .slide: class="title-slide" -->
<p class="kicker">For the CEO</p>

# Odoo, for testing

A safe place to try the business software

<p class="hint">Arrow keys to move · F for full screen</p>

Note: No technical background needed. Everything here happens in a web browser.

---

## What it is

- **Odoo**: sales, CRM, invoicing, inventory, projects, in one web app
- **beelink**: a small computer in the house that runs it
- **Testing only**: no customer, supplier or bank ever sees it

<p class="takeaway">A sandbox. Click everything. Nothing leaves the house.</p>

---

## You have seen this shape before

| The classic setup | Here |
| --- | --- |
| Server in the back room | **beelink** |
| Apache | **nginx** |
| MySQL | **PostgreSQL** |
| The PHP app | **Odoo** (Python) |
| Restore last night's backup | **reset**, in seconds |

<p class="hint">You never touch these parts: you use the browser.</p>

Note: Same idea as a LAMP server, newer parts. The person who runs beelink looks after all of it.

---

## Two test companies

<div class="diagram">
<svg class="sketch" viewBox="0 0 1100 420">
  <rect x="20" y="150" width="220" height="110" stroke="#6a9bcc" fill="#6a9bcc" />
  <text x="130" y="200" text-anchor="middle" fill="#faf9f5" font-size="30">Your laptop</text>
  <text x="130" y="235" text-anchor="middle" fill="#b0aea5" font-size="22">web browser</text>
  <line x1="245" y1="205" x2="365" y2="205" stroke="#faf9f5" data-arrow />
  <rect x="370" y="20" width="710" height="380" stroke="#d97757" fill="none" data-dash />
  <text x="725" y="60" text-anchor="middle" fill="#d97757" font-size="28">beelink</text>
  <rect x="400" y="90" width="300" height="120" stroke="#d97757" fill="#d97757" />
  <text x="550" y="140" text-anchor="middle" fill="#faf9f5" font-size="32">demo</text>
  <text x="550" y="178" text-anchor="middle" fill="#b0aea5" font-size="22">sample company, full of data</text>
  <rect x="400" y="250" width="300" height="120" stroke="#d97757" fill="#d97757" />
  <text x="550" y="300" text-anchor="middle" fill="#faf9f5" font-size="32">blank</text>
  <text x="550" y="338" text-anchor="middle" fill="#b0aea5" font-size="22">empty company</text>
  <g class="fragment fade-in">
    <line x1="705" y1="150" x2="815" y2="210" stroke="#faf9f5" data-arrow />
    <line x1="705" y1="310" x2="815" y2="250" stroke="#faf9f5" data-arrow />
    <rect x="820" y="170" width="230" height="120" stroke="#8fa876" fill="#8fa876" />
    <text x="935" y="222" text-anchor="middle" fill="#faf9f5" font-size="32">Mailpit</text>
    <text x="935" y="258" text-anchor="middle" fill="#b0aea5" font-size="22">every email</text>
  </g>
</svg>
</div>

Note: Each company is its own complete Odoo with its own data. What you do in one does not show up in the other.

---

## Where to go

| | Address |
| --- | --- |
| Start page | `odoo.beelink.home.arpa` |
| **demo** | `demo.odoo.beelink.home.arpa` |
| **blank** | `blank.odoo.beelink.home.arpa` |
| **Mailpit** | `mail.odoo.beelink.home.arpa` |

User **admin** · password: ask whoever runs beelink

<p class="hint">All start with https:// · home network only</p>

Note: The laptop needs a one-time setup so it can find beelink and trusts its padlock. "Your connection isn't private" means that setup is missing: stop and ask.

---

## Mailpit: the pretend mailbox

- Odoo emails quotes, invoices, reminders, password resets
- On beelink, **no email ever leaves the house**
- Mailpit keeps every one, like a post office that puts every letter in a tray

<p class="takeaway">Read every email exactly as the customer would, before a real one goes out.</p>

Note: Test data has made-up, sometimes real-looking addresses. Without Mailpit a test could email a stranger.

---

## A first test

1. **demo** → Sales → New quotation → Save
2. **Send** it
3. **Mailpit**: read the email, open the PDF <!-- .element: class="fragment" -->
4. Confirm → invoice → **Send** <!-- .element: class="fragment" -->
5. **Mailpit**: the invoice is there too <!-- .element: class="fragment" -->

<p class="hint">Not in Mailpit yet? Wait a few minutes, refresh.</p>

Note: Nothing was sent to anyone, and the customer is still made up.

---

## Starting over

| Ask for | You get |
| --- | --- |
| "Reset demo" | day one again, in seconds |
| "Save demo as *before-import*" | a bookmark of right now |
| "Put demo back to *before-import*" | everything as bookmarked |

<p class="hint">A reset fixes almost everything, including slow or stuck.</p>

---

## Ground rules

<ul class="ticks">
  <li>Try anything: send, delete, import</li>
  <li>Install apps from the Apps menu</li>
  <li>Reset whenever it gets messy</li>
</ul>
<ul class="ticks cross">
  <li>No real customer data, bank details or passwords</li>
</ul>

---

<!-- .slide: class="title-slide" -->

# Questions?

<p class="hint">The written guide: the "CEO: Odoo" page of these docs</p>
