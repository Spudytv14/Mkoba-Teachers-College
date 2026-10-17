-- Mkoba Teachers College e-Portal: Supabase starter database
-- Run the entire file in Supabase Dashboard -> SQL Editor -> New query.
-- Review this schema and test with separate Student, Teacher and Admin accounts before using real college records.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default 'Portal user',
  role text not null default 'student' check (role in ('student','teacher','admin')),
  requested_role text not null default 'student' check (requested_role in ('student','teacher','admin')),
  approval_status text not null default 'approved' check (approval_status in ('approved','pending','rejected')),
  class_name text,
  created_at timestamptz not null default now()
);

create table if not exists public.materials (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  subject text not null,
  description text,
  class_name text not null,
  teacher_id uuid not null references public.profiles(id),
  file_path text,
  created_at timestamptz not null default now()
);

create table if not exists public.assignments (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  subject text not null,
  instructions text not null,
  class_name text not null,
  teacher_id uuid not null references public.profiles(id),
  due_date timestamptz not null,
  created_at timestamptz not null default now()
);

create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  answer_text text not null,
  submitted_at timestamptz not null default now(),
  unique (assignment_id, student_id)
);

create table if not exists public.grades (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  class_name text not null,
  subject text not null,
  assessment text not null,
  score numeric(8,2) not null check (score >= 0),
  max_score numeric(8,2) not null check (max_score > 0),
  feedback text,
  teacher_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  check (score <= max_score)
);

create table if not exists public.timetable_events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  venue text,
  class_name text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  teacher_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  audience_class text,
  author_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.fees (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  description text not null,
  amount numeric(12,2) not null check (amount > 0),
  currency text not null default 'USD' check (currency in ('USD','ZiG')),
  due_date date,
  status text not null default 'unpaid' check (status in ('unpaid','paid','overdue','waived')),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

-- A payment report is a student-submitted reference for staff verification.
-- It is NOT a transaction and does not contact a bank, mobile-money provider or payment gateway.
create table if not exists public.payment_reports (
  id uuid primary key default gen_random_uuid(),
  fee_id uuid not null references public.fees(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  reference text not null,
  note text,
  status text not null default 'pending' check (status in ('pending','confirmed','rejected')),
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (length(trim(body)) > 0 and length(body) <= 10000),
  created_at timestamptz not null default now(),
  check (sender_id <> recipient_id)
);

create table if not exists public.attendance_records (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  class_name text not null,
  attendance_date date not null default current_date,
  status text not null check (status in ('present','absent','late')),
  subject text not null,
  marked_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

-- Access helper functions. SECURITY DEFINER avoids recursive profile-table RLS checks;
-- each helper only returns information about the currently authenticated account.
create or replace function public.current_app_role()
returns text
language sql stable security definer
set search_path = public
as $$ select role from public.profiles where id = auth.uid() limit 1 $$;

create or replace function public.current_class_name()
returns text
language sql stable security definer
set search_path = public
as $$ select class_name from public.profiles where id = auth.uid() limit 1 $$;

create or replace function public.can_access_class(target_class text)
returns boolean
language sql stable security definer
set search_path = public
as $$ select public.current_app_role() = 'admin' or (target_class is not null and target_class = public.current_class_name()) $$;

-- Signup trigger: all new accounts become students first. A user-supplied metadata
-- value can request teacher access, but it cannot grant a teacher/admin role.
create or replace function public.handle_new_portal_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  requested text;
begin
  requested := case when new.raw_user_meta_data ->> 'requested_role' = 'teacher' then 'teacher' else 'student' end;
  insert into public.profiles (id, full_name, role, requested_role, approval_status, class_name)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), 'Portal user'),
    'student',
    requested,
    case when requested = 'teacher' then 'pending' else 'approved' end,
    null
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_mkoba on auth.users;
create trigger on_auth_user_created_mkoba
after insert on auth.users
for each row execute procedure public.handle_new_portal_user();

-- Only an existing admin can change a user's role/class/approval status.
-- End users do not receive direct UPDATE permission on privileged profile fields.
create or replace function public.admin_update_profile_role(
  target_profile_id uuid,
  new_role text,
  new_class_name text,
  new_approval_status text default 'approved'
)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if public.current_app_role() is distinct from 'admin' then
    raise exception 'Administrator access is required.' using errcode = '42501';
  end if;
  if new_role not in ('student','teacher','admin') then
    raise exception 'Invalid role.' using errcode = '22023';
  end if;
  if new_approval_status not in ('approved','pending','rejected') then
    raise exception 'Invalid approval status.' using errcode = '22023';
  end if;
  update public.profiles
  set role = new_role,
      class_name = nullif(trim(coalesce(new_class_name,'')), ''),
      approval_status = new_approval_status,
      requested_role = case when new_role = 'teacher' then 'teacher' when new_role = 'admin' then 'admin' else 'student' end
  where id = target_profile_id;
  if not found then raise exception 'Profile not found.' using errcode = 'P0002'; end if;
end;
$$;

-- Turn on RLS on every application table.
alter table public.profiles enable row level security;
alter table public.materials enable row level security;
alter table public.assignments enable row level security;
alter table public.submissions enable row level security;
alter table public.grades enable row level security;
alter table public.timetable_events enable row level security;
alter table public.announcements enable row level security;
alter table public.fees enable row level security;
alter table public.payment_reports enable row level security;
alter table public.messages enable row level security;
alter table public.attendance_records enable row level security;

-- Explicit application grants. Revoke default/public table grants first; RLS policies alone do not remove SQL privileges.
revoke all on table public.profiles, public.materials, public.assignments, public.submissions,
  public.grades, public.timetable_events, public.announcements, public.fees,
  public.payment_reports, public.messages, public.attendance_records
from public, anon, authenticated;
grant usage on schema public to authenticated;
grant select on public.profiles to authenticated;
grant update (full_name) on public.profiles to authenticated;
grant select, insert, update, delete on public.materials to authenticated;
grant select, insert, update, delete on public.assignments to authenticated;
grant select, insert, update, delete on public.submissions to authenticated;
grant select, insert, update, delete on public.grades to authenticated;
grant select, insert, update, delete on public.timetable_events to authenticated;
grant select, insert, update, delete on public.announcements to authenticated;
grant select, insert, update, delete on public.fees to authenticated;
grant select, insert, update, delete on public.payment_reports to authenticated;
grant select, insert, delete on public.messages to authenticated;
grant select, insert, update, delete on public.attendance_records to authenticated;
revoke all on function public.current_app_role() from public, anon;
revoke all on function public.current_class_name() from public, anon;
revoke all on function public.can_access_class(text) from public, anon;
revoke all on function public.admin_update_profile_role(uuid,text,text,text) from public, anon;
grant execute on function public.current_app_role() to authenticated;
grant execute on function public.current_class_name() to authenticated;
grant execute on function public.can_access_class(text) to authenticated;
grant execute on function public.admin_update_profile_role(uuid,text,text,text) to authenticated;

-- Drop old versions so this setup can be re-run while testing.
drop policy if exists "profiles_read_authenticated_directory" on public.profiles;
drop policy if exists "profiles_update_own_name" on public.profiles;
drop policy if exists "materials_read_class" on public.materials;
drop policy if exists "materials_insert_teacher_admin" on public.materials;
drop policy if exists "materials_update_owner_admin" on public.materials;
drop policy if exists "materials_delete_owner_admin" on public.materials;
drop policy if exists "assignments_read_class" on public.assignments;
drop policy if exists "assignments_insert_teacher_admin" on public.assignments;
drop policy if exists "assignments_update_owner_admin" on public.assignments;
drop policy if exists "assignments_delete_owner_admin" on public.assignments;
drop policy if exists "submissions_read_owner_teacher_admin" on public.submissions;
drop policy if exists "submissions_insert_own_class" on public.submissions;
drop policy if exists "submissions_update_own_class" on public.submissions;
drop policy if exists "grades_read_student_teacher_admin" on public.grades;
drop policy if exists "grades_insert_teacher_admin" on public.grades;
drop policy if exists "grades_update_owner_admin" on public.grades;
drop policy if exists "grades_delete_owner_admin" on public.grades;
drop policy if exists "timetable_read_class" on public.timetable_events;
drop policy if exists "timetable_insert_teacher_admin" on public.timetable_events;
drop policy if exists "timetable_update_owner_admin" on public.timetable_events;
drop policy if exists "timetable_delete_owner_admin" on public.timetable_events;
drop policy if exists "announcements_read_audience" on public.announcements;
drop policy if exists "announcements_insert_teacher_admin" on public.announcements;
drop policy if exists "announcements_update_owner_admin" on public.announcements;
drop policy if exists "announcements_delete_owner_admin" on public.announcements;
drop policy if exists "fees_read_student_admin" on public.fees;
drop policy if exists "fees_insert_admin" on public.fees;
drop policy if exists "fees_update_admin" on public.fees;
drop policy if exists "fees_delete_admin" on public.fees;
drop policy if exists "payment_reports_read_student_admin" on public.payment_reports;
drop policy if exists "payment_reports_insert_own_fee" on public.payment_reports;
drop policy if exists "payment_reports_update_admin" on public.payment_reports;
drop policy if exists "payment_reports_delete_admin" on public.payment_reports;
drop policy if exists "messages_read_participants" on public.messages;
drop policy if exists "messages_insert_sender" on public.messages;
drop policy if exists "messages_update_recipient" on public.messages;
drop policy if exists "messages_delete_participants_admin" on public.messages;
drop policy if exists "messages_delete_sender" on public.messages;
drop policy if exists "attendance_read_student_teacher_admin" on public.attendance_records;
drop policy if exists "attendance_insert_teacher_admin" on public.attendance_records;
drop policy if exists "attendance_update_teacher_admin" on public.attendance_records;
drop policy if exists "attendance_delete_teacher_admin" on public.attendance_records;

-- Profiles: authenticated users can see the contact directory; private fields should not be added here
-- without reviewing this policy. Direct profile updates can change only full_name, never role/class.
create policy "profiles_read_authenticated_directory" on public.profiles
for select to authenticated using (true);
create policy "profiles_update_own_name" on public.profiles
for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Learning materials
create policy "materials_read_class" on public.materials for select to authenticated
using (public.can_access_class(class_name) or teacher_id = auth.uid());
create policy "materials_insert_teacher_admin" on public.materials for insert to authenticated
with check ((public.current_app_role() = 'admin') or (public.current_app_role() = 'teacher' and teacher_id = auth.uid() and class_name = public.current_class_name()));
create policy "materials_update_owner_admin" on public.materials for update to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid()))
with check (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid() and class_name = public.current_class_name()));
create policy "materials_delete_owner_admin" on public.materials for delete to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid()));

-- Assignments
create policy "assignments_read_class" on public.assignments for select to authenticated
using (public.can_access_class(class_name) or teacher_id = auth.uid());
create policy "assignments_insert_teacher_admin" on public.assignments for insert to authenticated
with check (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid() and class_name = public.current_class_name()));
create policy "assignments_update_owner_admin" on public.assignments for update to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid()))
with check (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid() and class_name = public.current_class_name()));
create policy "assignments_delete_owner_admin" on public.assignments for delete to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid()));

-- Student submissions: students see and edit their own work; the assignment teacher can review it.
create policy "submissions_read_owner_teacher_admin" on public.submissions for select to authenticated
using (student_id = auth.uid() or public.current_app_role() = 'admin' or exists (
  select 1 from public.assignments a where a.id = assignment_id and a.teacher_id = auth.uid()
));
create policy "submissions_insert_own_class" on public.submissions for insert to authenticated
with check (student_id = auth.uid() and public.current_app_role() = 'student' and exists (
  select 1 from public.assignments a where a.id = assignment_id and a.class_name = public.current_class_name()
));
create policy "submissions_update_own_class" on public.submissions for update to authenticated
using (student_id = auth.uid() and public.current_app_role() = 'student')
with check (student_id = auth.uid() and public.current_app_role() = 'student' and exists (
  select 1 from public.assignments a where a.id = assignment_id and a.class_name = public.current_class_name()
));

-- Marks
create policy "grades_read_student_teacher_admin" on public.grades for select to authenticated
using (student_id = auth.uid() or teacher_id = auth.uid() or public.current_app_role() = 'admin');
create policy "grades_insert_teacher_admin" on public.grades for insert to authenticated
with check (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid() and class_name = public.current_class_name() and exists (
  select 1 from public.profiles student where student.id = grades.student_id and student.role = 'student' and student.class_name = grades.class_name
)));
create policy "grades_update_owner_admin" on public.grades for update to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid()))
with check (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid() and class_name = public.current_class_name() and exists (
  select 1 from public.profiles student where student.id = grades.student_id and student.role = 'student' and student.class_name = grades.class_name
)));
create policy "grades_delete_owner_admin" on public.grades for delete to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid()));

-- Timetable
create policy "timetable_read_class" on public.timetable_events for select to authenticated
using (public.can_access_class(class_name) or teacher_id = auth.uid());
create policy "timetable_insert_teacher_admin" on public.timetable_events for insert to authenticated
with check (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid() and class_name = public.current_class_name()));
create policy "timetable_update_owner_admin" on public.timetable_events for update to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid()))
with check (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid() and class_name = public.current_class_name()));
create policy "timetable_delete_owner_admin" on public.timetable_events for delete to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and teacher_id = auth.uid()));

-- Announcements: teachers post to their own class; administrators may post to the whole college.
create policy "announcements_read_audience" on public.announcements for select to authenticated
using (audience_class is null or audience_class = public.current_class_name() or public.current_app_role() in ('teacher','admin'));
create policy "announcements_insert_teacher_admin" on public.announcements for insert to authenticated
with check (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and author_id = auth.uid() and audience_class = public.current_class_name()));
create policy "announcements_update_owner_admin" on public.announcements for update to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and author_id = auth.uid()))
with check (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and author_id = auth.uid() and audience_class = public.current_class_name()));
create policy "announcements_delete_owner_admin" on public.announcements for delete to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and author_id = auth.uid()));

-- Fees: only a student and college administrators can see the student's fee records.
create policy "fees_read_student_admin" on public.fees for select to authenticated
using (student_id = auth.uid() or public.current_app_role() = 'admin');
create policy "fees_insert_admin" on public.fees for insert to authenticated
with check (public.current_app_role() = 'admin' and created_by = auth.uid());
create policy "fees_update_admin" on public.fees for update to authenticated
using (public.current_app_role() = 'admin') with check (public.current_app_role() = 'admin');
create policy "fees_delete_admin" on public.fees for delete to authenticated
using (public.current_app_role() = 'admin');

-- Payment reports: students submit their own reference; admin verifies it. No automatic transaction processing.
create policy "payment_reports_read_student_admin" on public.payment_reports for select to authenticated
using (student_id = auth.uid() or public.current_app_role() = 'admin');
create policy "payment_reports_insert_own_fee" on public.payment_reports for insert to authenticated
with check (student_id = auth.uid() and public.current_app_role() = 'student' and exists (
  select 1 from public.fees f where f.id = fee_id and f.student_id = auth.uid() and payment_reports.amount <= f.amount
));
create policy "payment_reports_update_admin" on public.payment_reports for update to authenticated
using (public.current_app_role() = 'admin') with check (public.current_app_role() = 'admin');
create policy "payment_reports_delete_admin" on public.payment_reports for delete to authenticated
using (public.current_app_role() = 'admin');

-- Private one-to-one messages. Only sender and recipient can read them.
create policy "messages_read_participants" on public.messages for select to authenticated
using (sender_id = auth.uid() or recipient_id = auth.uid());
create policy "messages_insert_sender" on public.messages for insert to authenticated
with check (sender_id = auth.uid() and recipient_id <> auth.uid());
create policy "messages_delete_sender" on public.messages for delete to authenticated
using (sender_id = auth.uid());

-- Attendance: students see their own records; teachers see their assigned class; admins see all.
create policy "attendance_read_student_teacher_admin" on public.attendance_records for select to authenticated
using (student_id = auth.uid() or public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and class_name = public.current_class_name()));
create policy "attendance_insert_teacher_admin" on public.attendance_records for insert to authenticated
with check (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and marked_by = auth.uid() and class_name = public.current_class_name() and exists (
  select 1 from public.profiles student where student.id = attendance_records.student_id and student.role = 'student' and student.class_name = attendance_records.class_name
)));
create policy "attendance_update_teacher_admin" on public.attendance_records for update to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and marked_by = auth.uid() and class_name = public.current_class_name()))
with check (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and marked_by = auth.uid() and class_name = public.current_class_name() and exists (
  select 1 from public.profiles student where student.id = attendance_records.student_id and student.role = 'student' and student.class_name = attendance_records.class_name
)));
create policy "attendance_delete_teacher_admin" on public.attendance_records for delete to authenticated
using (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and marked_by = auth.uid()));

-- Private file storage for learning materials. Browser uploads are restricted to a class folder.
insert into storage.buckets (id, name, public)
values ('learning-materials','learning-materials',false)
on conflict (id) do update set public = false;

drop policy if exists "learning_materials_read_class" on storage.objects;
drop policy if exists "learning_materials_upload_teacher" on storage.objects;
drop policy if exists "learning_materials_delete_owner_admin" on storage.objects;
create policy "learning_materials_read_class" on storage.objects for select to authenticated
using (bucket_id = 'learning-materials' and (split_part(name,'/',1) = public.current_class_name() or public.current_app_role() = 'admin'));
create policy "learning_materials_upload_teacher" on storage.objects for insert to authenticated
with check (bucket_id = 'learning-materials' and (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and split_part(name,'/',1) = public.current_class_name() and split_part(name,'/',2) = auth.uid()::text)));
create policy "learning_materials_delete_owner_admin" on storage.objects for delete to authenticated
using (bucket_id = 'learning-materials' and (public.current_app_role() = 'admin' or (public.current_app_role() = 'teacher' and split_part(name,'/',2) = auth.uid()::text)));

-- Helpful indexes for lists and policy checks.
create index if not exists idx_profiles_role_class on public.profiles(role,class_name);
create index if not exists idx_materials_class_created on public.materials(class_name,created_at desc);
create index if not exists idx_assignments_class_due on public.assignments(class_name,due_date);
create index if not exists idx_submissions_assignment_student on public.submissions(assignment_id,student_id);
create index if not exists idx_grades_student_created on public.grades(student_id,created_at desc);
create index if not exists idx_timetable_class_start on public.timetable_events(class_name,starts_at);
create index if not exists idx_announcements_audience_created on public.announcements(audience_class,created_at desc);
create index if not exists idx_fees_student on public.fees(student_id,status);
create index if not exists idx_payment_reports_student on public.payment_reports(student_id,status);
create index if not exists idx_messages_sender_created on public.messages(sender_id,created_at desc);
create index if not exists idx_messages_recipient_created on public.messages(recipient_id,created_at desc);
create index if not exists idx_attendance_student_date on public.attendance_records(student_id,attendance_date desc);

-- First administrator bootstrap is documented in README.md. Do not expose a service_role key in the website.
