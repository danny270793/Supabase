-- Certifications Tracker: a price on certifications, and courses.
--
-- Courses live in their own table (they never show up in the certifications list).
-- Same conventions as cert_certifications: "userId" + RLS, soft delete ("deletedAt").

alter table public.cert_certifications
  add column price numeric(10, 2) not null default 0 check (price >= 0);

create table public.cert_courses (
  id uuid primary key default gen_random_uuid(),
  "userId" uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  -- Where it was taken: Udemy, LinkedIn Learning, ...
  provider text not null default '',
  price numeric(10, 2) not null default 0 check (price >= 0),
  "earnDate" date not null,
  -- Course length in hours.
  hours numeric(6, 1) not null default 0 check (hours >= 0),
  -- Lower-case labels such as 'python', 'devops'. These are the "categories" of the dashboard.
  tags text[] not null default '{}',
  -- Object path inside the 'cert-pdfs' bucket ('<userId>/courses/<id>.<pdf|jpg|png>').
  "filePath" text,
  "createdAt" timestamptz not null default now(),
  "updatedAt" timestamptz not null default now(),
  "deletedAt" timestamptz
);

create index cert_courses_user_earn_idx
  on public.cert_courses ("userId", "earnDate" desc) where "deletedAt" is null;

alter table public.cert_courses enable row level security;
alter table public.cert_courses force row level security;
revoke all on table public.cert_courses from anon;
revoke all on table public.cert_courses from public;
grant select, insert, update, delete on table public.cert_courses to authenticated;

create policy "Users can select their own rows" on public.cert_courses
  for select to authenticated using ((select auth.uid()) = "userId");
create policy "Users can insert their own rows" on public.cert_courses
  for insert to authenticated with check ((select auth.uid()) = "userId");
create policy "Users can update their own rows" on public.cert_courses
  for update to authenticated
  using ((select auth.uid()) = "userId")
  with check ((select auth.uid()) = "userId");
create policy "Users can delete their own rows" on public.cert_courses
  for delete to authenticated using ((select auth.uid()) = "userId");

-- Some course certificates are scans, so the bucket also accepts JPEG and PNG.
update storage.buckets
set allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png']
where id = 'cert-pdfs';
