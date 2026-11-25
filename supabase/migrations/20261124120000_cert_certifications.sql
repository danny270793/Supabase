-- Certifications Tracker: certifications with tags and an optional PDF.
--
-- Same conventions as the gym_ tables: every row carries "userId" so row level
-- security is a plain equality check, and rows are soft-deleted ("deletedAt").

create table public.cert_certifications (
  id uuid primary key default gen_random_uuid(),
  "userId" uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  provider text not null default '',
  "earnDate" date not null,
  -- Null = the certification does not expire.
  "expirationDate" date,
  "verificationUrl" text check ("verificationUrl" is null or "verificationUrl" ~* '^https?://'),
  -- Lower-case labels such as 'cloud', 'azure', 'database'.
  tags text[] not null default '{}',
  -- Object path inside the 'cert-pdfs' bucket ('<userId>/<id>.pdf'). Null = no PDF uploaded.
  "pdfPath" text,
  "createdAt" timestamptz not null default now(),
  "updatedAt" timestamptz not null default now(),
  "deletedAt" timestamptz,
  check ("expirationDate" is null or "expirationDate" >= "earnDate")
);

create index cert_certifications_user_earn_idx
  on public.cert_certifications ("userId", "earnDate" desc) where "deletedAt" is null;

-- ---------------------------------------------------------------------------
-- row level security: users only see and change their own rows
-- ---------------------------------------------------------------------------
alter table public.cert_certifications enable row level security;
alter table public.cert_certifications force row level security;
revoke all on table public.cert_certifications from anon;
revoke all on table public.cert_certifications from public;
grant select, insert, update, delete on table public.cert_certifications to authenticated;

create policy "Users can select their own rows" on public.cert_certifications
  for select to authenticated using ((select auth.uid()) = "userId");
create policy "Users can insert their own rows" on public.cert_certifications
  for insert to authenticated with check ((select auth.uid()) = "userId");
create policy "Users can update their own rows" on public.cert_certifications
  for update to authenticated
  using ((select auth.uid()) = "userId")
  with check ((select auth.uid()) = "userId");
create policy "Users can delete their own rows" on public.cert_certifications
  for delete to authenticated using ((select auth.uid()) = "userId");

-- ---------------------------------------------------------------------------
-- storage: private bucket, one folder per user ('<userId>/<file>.pdf')
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('cert-pdfs', 'cert-pdfs', false, 20971520, array['application/pdf'])
on conflict (id) do nothing;

create policy "Cert users can read their own PDFs"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'cert-pdfs'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Cert users can upload their own PDFs"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'cert-pdfs'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Cert users can update their own PDFs"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'cert-pdfs'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'cert-pdfs'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Cert users can delete their own PDFs"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'cert-pdfs'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
