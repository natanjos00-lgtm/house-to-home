-- House to Home: tabelas e segurança no Supabase.
-- Cada pessoa só enxerga e altera as próprias linhas (user_id = auth.uid()).
-- Pode ser executado mais de uma vez sem estragar nada.

create table if not exists public.records (
  user_id    uuid        not null default auth.uid() references auth.users(id) on delete cascade,
  coll       text        not null check (coll in ('_meta','items','pays','log','notes','rooms','sup')),
  id         text        not null check (char_length(id) between 1 and 100),
  data       jsonb       not null default '{}'::jsonb check (octet_length(data::text) < 200000),
  ord        integer,
  del        boolean     not null default false,
  updated_at timestamptz not null default now(),
  primary key (user_id, coll, id)
);

create table if not exists public.photos (
  user_id    uuid        not null default auth.uid() references auth.users(id) on delete cascade,
  id         text        not null check (char_length(id) between 1 and 100),
  data       text        not null check (char_length(data) < 900000),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists records_touch on public.records;
create trigger records_touch before update on public.records for each row execute function public.touch_updated_at();
drop trigger if exists photos_touch on public.photos;
create trigger photos_touch before update on public.photos for each row execute function public.touch_updated_at();

-- Segurança: sem login não há acesso nenhum; com login, só as próprias linhas.
alter table public.records enable row level security;
alter table public.photos  enable row level security;

revoke all on public.records from anon;
revoke all on public.photos  from anon;
grant select, insert, update, delete on public.records to authenticated;
grant select, insert, update, delete on public.photos  to authenticated;

drop policy if exists "records: dono lê"      on public.records;
drop policy if exists "records: dono cria"    on public.records;
drop policy if exists "records: dono altera"  on public.records;
drop policy if exists "records: dono apaga"   on public.records;
create policy "records: dono lê"     on public.records for select to authenticated using (user_id = (select auth.uid()));
create policy "records: dono cria"   on public.records for insert to authenticated with check (user_id = (select auth.uid()));
create policy "records: dono altera" on public.records for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "records: dono apaga"  on public.records for delete to authenticated using (user_id = (select auth.uid()));

drop policy if exists "photos: dono lê"      on public.photos;
drop policy if exists "photos: dono cria"    on public.photos;
drop policy if exists "photos: dono altera"  on public.photos;
drop policy if exists "photos: dono apaga"   on public.photos;
create policy "photos: dono lê"     on public.photos for select to authenticated using (user_id = (select auth.uid()));
create policy "photos: dono cria"   on public.photos for insert to authenticated with check (user_id = (select auth.uid()));
create policy "photos: dono altera" on public.photos for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "photos: dono apaga"  on public.photos for delete to authenticated using (user_id = (select auth.uid()));

-- Atualização em tempo real entre aparelhos (só linhas que a pessoa pode ler chegam a ela).
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='records') then
    alter publication supabase_realtime add table public.records;
  end if;
end $$;
