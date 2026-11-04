-- House to Home, parte 2: CASA COMPARTILHADA.
-- Rode DEPOIS do script 01 (que você já rodou). Pode ser executado mais de uma vez sem estragar nada.
-- Os dados passam a pertencer à CASA; as pessoas são membros dela. Seus dados atuais são preservados:
-- cada pessoa que já tinha dados ganha uma casa (como dona) com tudo o que ela tinha.

create table if not exists public.households (
  id         uuid primary key default gen_random_uuid(),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         text not null default 'member' check (role in ('owner','member')),
  created_at   timestamptz not null default now(),
  primary key (household_id, user_id),
  unique (user_id)                      -- cada pessoa pertence a uma casa só
);

create table if not exists public.household_invites (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  email        text not null check (email = lower(email) and char_length(email) between 3 and 254),
  invited_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (household_id, email)
);

-- Funções auxiliares usadas pelas regras (rodam com permissão própria, para não entrar em laço).
create or replace function public.is_member(h uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.household_members where household_id = h and user_id = auth.uid())
$$;
create or replace function public.is_owner(h uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.household_members where household_id = h and user_id = auth.uid() and role = 'owner')
$$;

-- Migração dos dados que já existem (só roda uma vez): cada pessoa vira dona de uma casa com os próprios dados.
do $$
declare r record; h uuid;
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='records' and column_name='household_id') then
    return;
  end if;
  alter table public.records add column household_id uuid;
  alter table public.photos  add column household_id uuid;
  for r in select distinct user_id from (select user_id from public.records union select user_id from public.photos) u where user_id is not null loop
    select household_id into h from public.household_members where user_id = r.user_id;
    if h is null then
      insert into public.households(created_by) values (r.user_id) returning id into h;
      insert into public.household_members(household_id, user_id, role) values (h, r.user_id, 'owner');
    end if;
    update public.records set household_id = h where user_id = r.user_id;
    update public.photos  set household_id = h where user_id = r.user_id;
  end loop;
  alter table public.records alter column household_id set not null;
  alter table public.photos  alter column household_id set not null;
  alter table public.records drop constraint records_pkey;
  alter table public.photos  drop constraint photos_pkey;
  alter table public.records add primary key (household_id, coll, id);
  alter table public.photos  add primary key (household_id, id);
  alter table public.records add constraint records_household_fk foreign key (household_id) references public.households(id) on delete cascade;
  alter table public.photos  add constraint photos_household_fk  foreign key (household_id) references public.households(id) on delete cascade;
  -- user_id passa a ser só "quem editou por último"; apagar uma conta não apaga os dados da casa
  alter table public.records alter column user_id drop not null;
  alter table public.photos  alter column user_id drop not null;
  alter table public.records drop constraint if exists records_user_id_fkey;
  alter table public.photos  drop constraint if exists photos_user_id_fkey;
  alter table public.records add constraint records_user_id_fkey foreign key (user_id) references auth.users(id) on delete set null;
  alter table public.photos  add constraint photos_user_id_fkey  foreign key (user_id) references auth.users(id) on delete set null;
end $$;

-- Segurança de tudo: sem login nada; com login, só a casa da qual a pessoa é membro.
alter table public.households        enable row level security;
alter table public.household_members enable row level security;
alter table public.household_invites enable row level security;
alter table public.records           enable row level security;
alter table public.photos            enable row level security;

revoke all on public.households, public.household_members, public.household_invites, public.records, public.photos from anon;
grant select on public.households, public.household_members, public.household_invites to authenticated;
grant select, insert, update, delete on public.records, public.photos to authenticated;
revoke insert, update, delete on public.households, public.household_members, public.household_invites from authenticated;

do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies where schemaname='public' and tablename in ('records','photos','households','household_members','household_invites') loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

create policy "casas: membro lê"    on public.households        for select to authenticated using (public.is_member(id));
create policy "membros: membro lê"  on public.household_members for select to authenticated using (public.is_member(household_id));
create policy "convites: membro lê" on public.household_invites for select to authenticated using (public.is_member(household_id));

create policy "records: membro lê"     on public.records for select to authenticated using (public.is_member(household_id));
create policy "records: membro cria"   on public.records for insert to authenticated with check (public.is_member(household_id));
create policy "records: membro altera" on public.records for update to authenticated using (public.is_member(household_id)) with check (public.is_member(household_id));
create policy "records: dono apaga"    on public.records for delete to authenticated using (public.is_owner(household_id));

create policy "photos: membro lê"     on public.photos for select to authenticated using (public.is_member(household_id));
create policy "photos: membro cria"   on public.photos for insert to authenticated with check (public.is_member(household_id));
create policy "photos: membro altera" on public.photos for update to authenticated using (public.is_member(household_id)) with check (public.is_member(household_id));
create policy "photos: dono apaga"    on public.photos for delete to authenticated using (public.is_owner(household_id));

-- Quem editou por último é registrado pelo banco (não dá para falsificar).
create or replace function public.set_author() returns trigger
language plpgsql set search_path = '' as $$
begin new.user_id := coalesce(auth.uid(), new.user_id); return new; end $$;
drop trigger if exists records_author on public.records;
create trigger records_author before insert or update on public.records for each row execute function public.set_author();
drop trigger if exists photos_author on public.photos;
create trigger photos_author before insert or update on public.photos for each row execute function public.set_author();

-- Entrar na casa: aceita convite feito para o seu e-mail ou, se não houver, cria a sua casa.
create or replace function public.ensure_household() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); em text; inv record; cur uuid; n int; nh uuid; blocked boolean := false; joined boolean := false; has_data boolean;
begin
  if uid is null then raise exception 'Faça login para continuar.' using errcode = '28000'; end if;
  select lower(email) into em from auth.users where id = uid;
  select household_id into cur from public.household_members where user_id = uid;
  select * into inv from public.household_invites where email = em order by created_at limit 1;
  if found and cur is distinct from inv.household_id then
    if cur is not null then
      select count(*) into n from public.household_members where household_id = cur;
      has_data := exists (select 1 from public.records where household_id = cur and coll in ('items','pays','log','notes','sup') and del = false)
               or exists (select 1 from public.photos where household_id = cur);
      if n = 1 and not has_data then
        delete from public.households where id = cur; cur := null;   -- casa vazia e sozinha: pode trocar pela do convite
      else
        blocked := true;                                              -- já tem dados: não troca sozinho
      end if;
    end if;
    if cur is null then
      insert into public.household_members(household_id, user_id, role) values (inv.household_id, uid, 'member');
      delete from public.household_invites where email = em and household_id = inv.household_id;
      cur := inv.household_id; joined := true;
    end if;
  elsif found then
    delete from public.household_invites where id = inv.id;           -- convite para a casa em que já está
  end if;
  if cur is null then
    insert into public.households(created_by) values (uid) returning id into nh;
    insert into public.household_members(household_id, user_id, role) values (nh, uid, 'owner');
    cur := nh;
  end if;
  return jsonb_build_object('household_id', cur, 'joined', joined, 'blocked', blocked);
end $$;

-- Quem está na casa, convites pendentes e o seu papel.
create or replace function public.household_info() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := auth.uid(); h uuid; r text; em text;
begin
  if uid is null then raise exception 'Faça login para continuar.' using errcode = '28000'; end if;
  select household_id, role into h, r from public.household_members where user_id = uid;
  select lower(email) into em from auth.users where id = uid;
  return jsonb_build_object('household_id', h, 'role', r,
    'members', coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'email', u.email, 'role', m.role) order by m.created_at)
                         from public.household_members m join auth.users u on u.id = m.user_id where m.household_id = h), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email) order by i.created_at)
                         from public.household_invites i where i.household_id = h), '[]'::jsonb),
    'pending_elsewhere', exists (select 1 from public.household_invites i where i.email = em and i.household_id is distinct from h));
end $$;

create or replace function public.invite_member(p_email text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); h uuid; em text := lower(btrim(coalesce(p_email, ''))); n int;
begin
  if uid is null then raise exception 'Faça login para continuar.' using errcode = '28000'; end if;
  select household_id into h from public.household_members where user_id = uid and role = 'owner';
  if h is null then raise exception 'Só quem criou a casa pode convidar pessoas.'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(em) > 254 then raise exception 'Digite um e-mail válido.'; end if;
  if exists (select 1 from public.household_members m join auth.users u on u.id = m.user_id where m.household_id = h and lower(u.email) = em) then
    raise exception 'Essa pessoa já está na casa.'; end if;
  select (select count(*) from public.household_members where household_id = h) + (select count(*) from public.household_invites where household_id = h) into n;
  if n >= 6 then raise exception 'A casa já tem o máximo de 6 pessoas e convites.'; end if;
  insert into public.household_invites(household_id, email, invited_by) values (h, em, uid) on conflict (household_id, email) do nothing;
  return jsonb_build_object('ok', true, 'email', em);
end $$;

create or replace function public.cancel_invite(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); h uuid;
begin
  if uid is null then raise exception 'Faça login para continuar.' using errcode = '28000'; end if;
  select household_id into h from public.household_members where user_id = uid and role = 'owner';
  if h is null then raise exception 'Só quem criou a casa pode cancelar convites.'; end if;
  delete from public.household_invites where id = p_id and household_id = h;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.remove_member(p_user uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); h uuid; k int;
begin
  if uid is null then raise exception 'Faça login para continuar.' using errcode = '28000'; end if;
  select household_id into h from public.household_members where user_id = uid and role = 'owner';
  if h is null then raise exception 'Só quem criou a casa pode remover pessoas.'; end if;
  if p_user = uid then raise exception 'Você é a dona ou o dono da casa e não pode se remover.'; end if;
  delete from public.household_members where household_id = h and user_id = p_user;
  get diagnostics k = row_count;
  if k = 0 then raise exception 'Essa pessoa não está na casa.'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.leave_household() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); k int;
begin
  if uid is null then raise exception 'Faça login para continuar.' using errcode = '28000'; end if;
  if exists (select 1 from public.household_members where user_id = uid and role = 'owner') then
    raise exception 'Quem criou a casa não pode sair. Remova as outras pessoas ou apague a casa.'; end if;
  delete from public.household_members where user_id = uid;
  get diagnostics k = row_count;
  return jsonb_build_object('ok', k > 0);
end $$;

revoke all on function public.ensure_household(), public.household_info(), public.invite_member(text), public.cancel_invite(uuid), public.remove_member(uuid), public.leave_household(), public.is_member(uuid), public.is_owner(uuid) from public, anon;
grant execute on function public.ensure_household(), public.household_info(), public.invite_member(text), public.cancel_invite(uuid), public.remove_member(uuid), public.leave_household(), public.is_member(uuid), public.is_owner(uuid) to authenticated;
