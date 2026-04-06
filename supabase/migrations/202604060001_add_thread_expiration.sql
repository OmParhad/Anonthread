-- Add thread-expiration support to threads.
alter table public.threads
  add column if not exists expires_at timestamptz,
  add column if not exists is_expired boolean not null default false,
  add column if not exists ttl_hours integer;

-- Backfill existing rows using a default 24-hour TTL when expires_at is missing.
update public.threads
set expires_at = created_at + interval '24 hours'
where expires_at is null;

-- Enforce NOT NULL once backfill is complete.
alter table public.threads
  alter column expires_at set not null;

-- Optional safety check so ttl_hours (if provided) is positive.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'threads_ttl_hours_positive_check'
      and conrelid = 'public.threads'::regclass
  ) then
    alter table public.threads
      add constraint threads_ttl_hours_positive_check
      check (ttl_hours is null or ttl_hours > 0);
  end if;
end $$;

-- Composite index to accelerate active-thread filtering and expiration sweeps.
create index if not exists idx_threads_is_expired_expires_at
  on public.threads (is_expired, expires_at);

-- If RLS is enabled on posts, add a restrictive insert policy that only allows
-- posts linked to non-expired threads.
do $$
declare
  posts_rls_enabled boolean;
begin
  select c.relrowsecurity
  into posts_rls_enabled
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'posts';

  if posts_rls_enabled then
    if not exists (
      select 1
      from pg_policies
      where schemaname = 'public'
        and tablename = 'posts'
        and policyname = 'posts_insert_only_active_threads'
    ) then
      execute $policy$
        create policy posts_insert_only_active_threads
        as restrictive
        on public.posts
        for insert
        to public
        with check (
          exists (
            select 1
            from public.threads t
            where t.id = thread_id
              and t.is_expired = false
              and t.expires_at > now()
          )
        )
      $policy$;
    end if;
  end if;
end $$;
