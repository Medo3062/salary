create extension if not exists pgcrypto with schema extensions;
create extension if not exists supabase_vault with schema vault;
revoke all on vault.decrypted_secrets, vault.secrets from public, anon, authenticated;

create table if not exists public.superadmin_accounts (
  username text primary key,
  password_hash text not null
);

create table if not exists public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  is_active boolean not null default true,
  employee_username text not null unique,
  employee_password_hash text not null,
  employee_password_ciphertext bytea not null,
  manager_username text not null unique,
  manager_password_hash text not null,
  manager_password_ciphertext bytea not null,
  created_at timestamptz not null default now()
);

create table if not exists public.app_sessions (
  token_hash text primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  role text not null check (role in ('employee', 'manager')),
  device_id text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (company_id, role)
);

create table if not exists public.superadmin_sessions (
  token_hash text primary key,
  username text not null references public.superadmin_accounts(username) on delete cascade,
  device_id text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.employee_months (
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  year integer not null check (year between 2000 and 2100),
  month integer not null check (month between 1 and 12),
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (employee_id, year, month)
);

alter table public.superadmin_accounts enable row level security;
alter table public.companies enable row level security;
alter table public.app_sessions enable row level security;
alter table public.superadmin_sessions enable row level security;
alter table public.employees enable row level security;
alter table public.employee_months enable row level security;

revoke all on public.superadmin_accounts, public.companies,
  public.app_sessions, public.superadmin_sessions, public.employees,
  public.employee_months from anon, authenticated;

create or replace function public._company_password_key()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
begin
  select s.decrypted_secret into v_key
  from vault.decrypted_secrets s
  where s.name = 'company-password-encryption-key'
  limit 1;
  if v_key is null then
    raise exception 'company password encryption key is not configured in Supabase Vault';
  end if;
  return v_key;
end;
$$;

create or replace function public._session_role(p_session_token text)
returns text
language sql
security definer
set search_path = ''
as $$
  select s.role
  from public.app_sessions s
  join public.companies c on c.id = s.company_id and c.is_active
  where s.token_hash = encode(extensions.digest(convert_to(p_session_token, 'UTF8'), 'sha256'), 'hex')
    and s.expires_at > now()
$$;

create or replace function public._session_company(p_session_token text)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select s.company_id
  from public.app_sessions s
  join public.companies c on c.id = s.company_id and c.is_active
  where s.token_hash = encode(extensions.digest(convert_to(p_session_token, 'UTF8'), 'sha256'), 'hex')
    and s.expires_at > now()
$$;

create or replace function public._is_superadmin(p_session_token text)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.superadmin_sessions s
    where s.token_hash = encode(extensions.digest(convert_to(p_session_token, 'UTF8'), 'sha256'), 'hex')
      and s.expires_at > now()
  )
$$;

create or replace function public.company_login(
  p_username text,
  p_password text,
  p_role text,
  p_device_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company public.companies%rowtype;
  v_password_hash text;
  v_token text;
begin
  if p_role not in ('employee', 'manager') then
    return jsonb_build_object('status', 'invalid');
  end if;

  select * into v_company
  from public.companies c
  where (p_role = 'employee' and c.employee_username = p_username)
     or (p_role = 'manager' and c.manager_username = p_username);

  if not found then
    return jsonb_build_object('status', 'invalid');
  end if;
  if not v_company.is_active then
    return jsonb_build_object('status', 'disabled');
  end if;

  v_password_hash := case p_role
    when 'employee' then v_company.employee_password_hash
    else v_company.manager_password_hash
  end;
  if extensions.crypt(p_password, v_password_hash) <> v_password_hash then
    return jsonb_build_object('status', 'invalid');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_company.id::text || ':' || p_role, 0));
  delete from public.app_sessions
  where company_id = v_company.id and role = p_role and expires_at <= now();

  if exists (
    select 1 from public.app_sessions s
    where s.company_id = v_company.id and s.role = p_role and s.expires_at > now()
  ) then
    return jsonb_build_object('status', 'locked');
  end if;

  v_token := gen_random_uuid()::text || gen_random_uuid()::text;
  insert into public.app_sessions(token_hash, company_id, role, device_id, expires_at)
  values (
    encode(extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex'),
    v_company.id,
    p_role,
    p_device_id,
    now() + interval '10 minutes'
  );

  return jsonb_build_object(
    'status', 'ok',
    'session_token', v_token,
    'role', p_role,
    'company_id', v_company.id,
    'company_name', v_company.name,
    'username', p_username
  );
end;
$$;

create or replace function public.superadmin_login(
  p_username text,
  p_password text,
  p_role text,
  p_device_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account public.superadmin_accounts%rowtype;
  v_token text;
begin
  if p_role <> 'superadmin' then
    return jsonb_build_object('status', 'invalid');
  end if;
  select * into v_account from public.superadmin_accounts where username = p_username;
  if not found or extensions.crypt(p_password, v_account.password_hash) <> v_account.password_hash then
    return jsonb_build_object('status', 'invalid');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('salary-superadmin', 0));
  delete from public.superadmin_sessions where expires_at <= now();
  if exists (select 1 from public.superadmin_sessions where expires_at > now()) then
    return jsonb_build_object('status', 'locked');
  end if;

  v_token := gen_random_uuid()::text || gen_random_uuid()::text;
  insert into public.superadmin_sessions(token_hash, username, device_id, expires_at)
  values (
    encode(extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex'),
    p_username,
    p_device_id,
    now() + interval '10 minutes'
  );
  return jsonb_build_object(
    'status', 'ok',
    'session_token', v_token,
    'role', 'superadmin',
    'company_id', null,
    'company_name', null,
    'username', p_username
  );
end;
$$;

create or replace function public.app_session_heartbeat(p_session_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := encode(extensions.digest(convert_to(p_session_token, 'UTF8'), 'sha256'), 'hex');
  v_updated integer;
begin
  update public.app_sessions s set expires_at = now() + interval '10 minutes'
  from public.companies c
  where s.company_id = c.id and c.is_active
    and s.token_hash = v_hash and s.expires_at > now();
  get diagnostics v_updated = row_count;
  if v_updated > 0 then return true; end if;

  update public.superadmin_sessions set expires_at = now() + interval '10 minutes'
  where token_hash = v_hash and expires_at > now();
  get diagnostics v_updated = row_count;
  return v_updated > 0;
end;
$$;

create or replace function public.app_session_logout(p_session_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := encode(extensions.digest(convert_to(p_session_token, 'UTF8'), 'sha256'), 'hex');
begin
  delete from public.app_sessions where token_hash = v_hash;
  delete from public.superadmin_sessions where token_hash = v_hash;
end;
$$;

create or replace function public.superadmin_list_companies(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public._is_superadmin(p_session_token) then raise exception 'unauthorized'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id,
      'name', c.name,
      'is_active', c.is_active,
      'employee_username', c.employee_username,
      'employee_password', convert_from(
        extensions.pgp_sym_decrypt_bytea(c.employee_password_ciphertext, public._company_password_key()),
        'UTF8'
      ),
      'manager_username', c.manager_username,
      'manager_password', convert_from(
        extensions.pgp_sym_decrypt_bytea(c.manager_password_ciphertext, public._company_password_key()),
        'UTF8'
      )
    ) order by c.name)
    from public.companies c
  ), '[]'::jsonb);
end;
$$;

create or replace function public.superadmin_create_company(
  p_session_token text,
  p_name text,
  p_employee_username text,
  p_employee_password text,
  p_manager_username text,
  p_manager_password text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company public.companies%rowtype;
begin
  if not public._is_superadmin(p_session_token) then raise exception 'unauthorized'; end if;
  if length(trim(p_name)) = 0 or length(trim(p_employee_username)) = 0
     or length(trim(p_manager_username)) = 0 or length(p_employee_password) < 8
     or length(p_manager_password) < 8 then
    raise exception 'invalid company details';
  end if;
  insert into public.companies(
    name, employee_username, employee_password_hash, employee_password_ciphertext,
    manager_username, manager_password_hash, manager_password_ciphertext
  ) values (
    trim(p_name),
    trim(p_employee_username),
    extensions.crypt(p_employee_password, extensions.gen_salt('bf')),
    extensions.pgp_sym_encrypt(p_employee_password, public._company_password_key()),
    trim(p_manager_username),
    extensions.crypt(p_manager_password, extensions.gen_salt('bf')),
    extensions.pgp_sym_encrypt(p_manager_password, public._company_password_key())
  ) returning * into v_company;
  return jsonb_build_object(
    'id', v_company.id,
    'name', v_company.name,
    'is_active', v_company.is_active,
    'employee_username', v_company.employee_username,
    'manager_username', v_company.manager_username
  );
end;
$$;

create or replace function public.superadmin_update_company(
  p_session_token text,
  p_company_id uuid,
  p_active boolean,
  p_employee_username text,
  p_employee_password text,
  p_manager_username text,
  p_manager_password text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public._is_superadmin(p_session_token) then raise exception 'unauthorized'; end if;
  if length(trim(p_employee_username)) = 0 or length(trim(p_manager_username)) = 0
     or (p_employee_password <> '' and length(p_employee_password) < 8)
     or (p_manager_password <> '' and length(p_manager_password) < 8) then
    raise exception 'invalid company details';
  end if;
  update public.companies set
    is_active = coalesce(p_active, is_active),
    employee_username = trim(p_employee_username),
    employee_password_hash = case when p_employee_password = '' then employee_password_hash
      else extensions.crypt(p_employee_password, extensions.gen_salt('bf')) end,
    employee_password_ciphertext = case when p_employee_password = '' then employee_password_ciphertext
      else extensions.pgp_sym_encrypt(p_employee_password, public._company_password_key()) end,
    manager_username = trim(p_manager_username),
    manager_password_hash = case when p_manager_password = '' then manager_password_hash
      else extensions.crypt(p_manager_password, extensions.gen_salt('bf')) end,
    manager_password_ciphertext = case when p_manager_password = '' then manager_password_ciphertext
      else extensions.pgp_sym_encrypt(p_manager_password, public._company_password_key()) end
  where id = p_company_id;
  if not found then raise exception 'company not found'; end if;
  delete from public.app_sessions where company_id = p_company_id;
end;
$$;

create or replace function public.company_list_employees(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
begin
  if v_company_id is null then raise exception 'unauthorized'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name) order by lower(e.name))
    from public.employees e where e.company_id = v_company_id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.company_create_employee(p_session_token text, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
  v_employee public.employees%rowtype;
begin
  if v_company_id is null or public._session_role(p_session_token) <> 'manager' then
    raise exception 'unauthorized';
  end if;
  if length(trim(p_name)) = 0 then raise exception 'employee name required'; end if;
  insert into public.employees(company_id, name)
  values (v_company_id, trim(p_name)) returning * into v_employee;
  return jsonb_build_object('id', v_employee.id, 'name', v_employee.name);
end;
$$;

create or replace function public.company_list_months(p_session_token text, p_employee_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
begin
  if v_company_id is null or not exists (
    select 1 from public.employees e where e.id = p_employee_id and e.company_id = v_company_id
  ) then raise exception 'unauthorized'; end if;
  return coalesce((
    select jsonb_agg(
      (case when public._session_role(p_session_token) = 'employee'
        then m.data - 'hourlyRate' - 'vacationDays' - 'workDays'
        else m.data end) || jsonb_build_object('year', m.year, 'month', m.month)
      order by m.year desc, m.month desc)
    from public.employee_months m
    where m.company_id = v_company_id and m.employee_id = p_employee_id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.company_save_month(
  p_session_token text,
  p_employee_id uuid,
  p_year integer,
  p_month integer,
  p_data jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
begin
  if v_company_id is null or not exists (
    select 1 from public.employees e where e.id = p_employee_id and e.company_id = v_company_id
  ) then raise exception 'unauthorized'; end if;
  if p_year not between 2000 and 2100 or p_month not between 1 and 12 then
    raise exception 'invalid month';
  end if;
  if public._session_role(p_session_token) = 'manager' then
    insert into public.employee_months(company_id, employee_id, year, month, data)
    values (v_company_id, p_employee_id, p_year, p_month, p_data)
    on conflict (employee_id, year, month) do update
      set data = excluded.data, updated_at = now();
  elsif public._session_role(p_session_token) = 'employee' then
    update public.employee_months set
      data = jsonb_set(data, '{days}', coalesce(p_data -> 'days', '{}'::jsonb), true),
      updated_at = now()
    where company_id = v_company_id and employee_id = p_employee_id
      and year = p_year and month = p_month;
    if not found then
      insert into public.employee_months(company_id, employee_id, year, month, data)
      values (
        v_company_id, p_employee_id, p_year, p_month,
        jsonb_build_object(
          'year', p_year,
          'month', p_month,
          'vacationDays', 0,
          'workDays', 30,
          'days', coalesce(p_data -> 'days', '{}'::jsonb)
        )
      );
    end if;
  else
    raise exception 'unauthorized';
  end if;
end;
$$;

create or replace function public.company_delete_month(
  p_session_token text,
  p_employee_id uuid,
  p_year integer,
  p_month integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
begin
  if v_company_id is null or public._session_role(p_session_token) <> 'manager'
     or not exists (
       select 1 from public.employees e where e.id = p_employee_id and e.company_id = v_company_id
     ) then raise exception 'unauthorized'; end if;
  delete from public.employee_months
  where company_id = v_company_id and employee_id = p_employee_id
    and year = p_year and month = p_month;
end;
$$;

revoke execute on all functions in schema public from public;
revoke execute on function public._company_password_key() from public, anon, authenticated;
grant execute on function public.company_login(text, text, text, text) to anon, authenticated;
grant execute on function public.superadmin_login(text, text, text, text) to anon, authenticated;
grant execute on function public.app_session_heartbeat(text) to anon, authenticated;
grant execute on function public.app_session_logout(text) to anon, authenticated;
grant execute on function public.superadmin_list_companies(text) to anon, authenticated;
grant execute on function public.superadmin_create_company(text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.superadmin_update_company(text, uuid, boolean, text, text, text, text) to anon, authenticated;
grant execute on function public.company_list_employees(text) to anon, authenticated;
grant execute on function public.company_create_employee(text, text) to anon, authenticated;
grant execute on function public.company_list_months(text, uuid) to anon, authenticated;
grant execute on function public.company_save_month(text, uuid, integer, integer, jsonb) to anon, authenticated;
grant execute on function public.company_delete_month(text, uuid, integer, integer) to anon, authenticated;
