# Mkoba Teachers College e-Portal — starter website

This starter package contains a responsive college portal with **separate Student, Teacher and Administrator experiences**. It uses one website with role-based navigation. The included demo lets you explore the screens without creating a database.

## Included features

- Student and teacher sign-in / self-registration
- Teacher access requests that remain pending until an administrator approves them
- Class learning materials, with private file storage when connected to Supabase
- Assignments and written submissions
- Marks and feedback
- Class timetable and announcements
- Student fee records and student-submitted payment references for finance-office verification
- Direct messages between portal users
- Attendance records
- Administrator controls for approving teacher access, setting account roles and assigning classes

**Important:** This is a starter version, not a college-approved live system. Test it with fake accounts and sample data first. Do not upload real marks, fee balances or student records until the college approves the workflow and the access policies have been reviewed and tested.

## Files

- `index.html` — the page entry point
- `styles.css` — responsive design and styling
- `app.js` — portal interface, Supabase connection settings and interactions
- `setup.sql` — database tables, sign-up trigger, role-management function and row-level security policies

## Step 1 — Preview the website

1. Download and extract the ZIP file.
2. Open `index.html` in a modern browser.
3. Choose **Student preview**, **Teacher preview** or **Admin preview**.
4. Click through the portal sections and try forms. Demo changes are temporary and reset when the page is refreshed.

Demo mode does not authenticate anyone and must not be used to store real information.

## Step 2 — Create a Supabase project

1. Go to [Supabase](https://supabase.com/) and create a project.
2. Save the database password somewhere secure.
3. In the project dashboard, open **SQL Editor** and create a new query.
4. Copy the full contents of `setup.sql` into the query and run it.
5. Confirm the query completes without an error. If you are re-running a partial setup after an error, fix the error first rather than assuming every table and policy exists.

The SQL creates the database tables and enables row-level security (RLS). It also creates a private Storage bucket named `learning-materials` for class files.

## Step 3 — Connect the website to Supabase

1. In Supabase, open the project's **Connect** panel or **Project Settings → API**.
2. Copy the **Project URL**.
3. Copy the public **publishable key** (or legacy `anon` key, if that is what your project shows).
4. Open `app.js` in a text editor.
5. Near the top, replace these two placeholders:

```js
const SUPABASE_URL = "YOUR_SUPABASE_PROJECT_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY";
```

Use the actual Project URL and **public** publishable/anon key. Never paste a `service_role` or secret key into `app.js`, HTML, GitHub, or any browser code. The public key is expected to be visible to visitors; the database's RLS policies are what control access.

6. Save `app.js`, then reload `index.html`. The demo buttons will disappear and the real sign-in form will be used.

## Step 4 — Configure email sign-in

In the Supabase dashboard, open **Authentication → URL Configuration**. Add the URL where you will test/deploy the portal to the allowed redirect URLs. Keep email confirmation enabled for real accounts and test the confirmation email flow. During local testing, redirect settings may need to include your local address or the final hosted URL.

New users can register themselves. The database always creates the account with the `student` role. Selecting **Teacher — request staff access** only marks the account as a pending teacher request; it does not grant teacher privileges.

## Step 5 — Make the first administrator

This is a one-time bootstrap. It is safer to assign the first admin from the Supabase SQL Editor rather than expose an admin registration option publicly.

1. Register your own account through the portal using an email you control.
2. Confirm the email and sign in once so the profile has been created.
3. Open Supabase **SQL Editor** and run the following, replacing the example email with your exact account email:

```sql
update public.profiles
set role = 'admin',
    requested_role = 'admin',
    approval_status = 'approved',
    class_name = null
where id = (
  select id from auth.users where lower(email) = lower('your.email@example.com')
);
```

4. Sign out of the portal and sign in again. Your account should now show Administration in the sidebar.
5. In Administration, approve verified teacher requests and assign class names such as `ECE-A` or `Primary-1`. Use the exact same class name for all people and resources in that class.

If the update affects zero rows, check the email address and confirm you have signed up and verified it. Do not give administrator access to ordinary student accounts.

## Step 6 — Publish on GitHub Pages

1. Create a GitHub repository called `mkoba-teachers-portal`.
2. Upload `index.html`, `styles.css`, `app.js`, `setup.sql` and `README.md` to the repository's root.
3. Open the repository's **Settings → Pages**.
4. Under the publishing source, choose **Deploy from a branch**, select `main` and `/(root)`, then save.
5. Once published, open the provided GitHub Pages URL and test it in a private/incognito browser window.
6. Add that deployed URL to Supabase's allowed redirect URLs and test registration, email confirmation, login and sign-out again.

GitHub Pages serves a static website. The Supabase project handles authentication and data. A GitHub Pages website is publicly accessible, so never put private college data, passwords or secret keys in the repository.

## Step 7 — Test accounts and permissions before launch

Use at least three separate test accounts:

1. **Student:** Can see their own marks, fee records, attendance and messages, and class resources after an administrator assigns a class.
2. **Teacher:** Request staff access, then ask the administrator to approve the account and assign a class. Verify that the teacher can publish resources and record results only for the assigned class.
3. **Administrator:** Can approve teacher requests, assign classes, create fee records and manage roles.

Also test that a student cannot read another student's results/fees/messages, cannot create assignments or marks, and cannot change their role. Test by signing in separately as each account—not by relying on the demo preview.

## Current limitations / next steps

- Fee records and payment references are **not** real payment processing. Students can report a reference; finance staff must verify it outside the portal before marking a fee as paid. A payment gateway would require a separate, server-side integration.
- Assignment submissions currently use text responses. File attachments for student submissions, password-reset UI, notification delivery, audit logs and richer reporting still need to be added before production.
- Class membership is currently represented by a single `class_name` on each profile. If staff teach multiple classes or students take different subjects, upgrade this to dedicated course/class membership tables.
- Messaging is a basic inbox/sent list, not real-time chat.
- Before go-live, have a qualified developer review the SQL/RLS policies, backup and recovery, account recovery, privacy obligations, access logs and the college's data-retention rules.

## Technical notes

The site loads `supabase-js` v2 from jsDelivr. All trusted authorisation checks live in PostgreSQL policies and the `admin_update_profile_role` database function, not in frontend controls alone. Supabase documentation: [Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security), [JavaScript sign-up](https://supabase.com/docs/reference/javascript/auth-signup), and [Storage access control](https://supabase.com/docs/guides/storage/security/access-control).
