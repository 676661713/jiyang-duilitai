-- 吉羊货栈兑礼台 · Supabase/Postgres 建库脚本
-- 通过 Management API: POST /v1/projects/{ref}/database/query 执行
-- 可重复执行（幂等）

-- ===== 表 =====
create table if not exists public.redemptions (
  key        text primary key,              -- 规范化(部门)+'|'+规范化(姓名)：去空格、英文小写、NFKC
  dept       text not null,
  name       text not null,
  tickets    int  not null check (tickets >= 0),
  tier       text not null check (tier in ('大礼','中礼','小礼','保底礼')),
  downgraded boolean not null default false, -- true=原本应得大礼、因大礼兑完按中礼发放
  at         timestamptz not null default now(),
  by         text not null default ''        -- 经手人/台号
);

create table if not exists public.redemptions_void (  -- 作废留档（审计用，不参与查重）
  like public.redemptions,
  voided_at timestamptz not null default now()
);

create table if not exists public.config (
  id        text primary key,
  big_stock int not null default 50          -- 大礼限量份数
);
insert into public.config (id, big_stock) values ('main', 50)
on conflict (id) do nothing;

create table if not exists public.secrets (  -- 口令只经 RPC 校验，anon 不可读
  id         text primary key,
  staff_code text not null,
  admin_pass text not null
);
insert into public.secrets (id, staff_code, admin_pass)
values ('main', 'JL-6688', 'ZG-2026-XY')      -- 默认口令，README 写了改法；正式启用前改掉
on conflict (id) do nothing;

-- ===== 行级安全 =====
alter table public.redemptions      enable row level security;
alter table public.redemptions_void enable row level security;
alter table public.config           enable row level security;
alter table public.secrets          enable row level security;

drop policy if exists "anon read redemptions" on public.redemptions;
create policy "anon read redemptions" on public.redemptions
  for select to anon using (true);

drop policy if exists "anon read config" on public.config;
create policy "anon read config" on public.config
  for select to anon using (true);
-- secrets / redemptions_void：无策略 = anon 完全不可见；写操作一律走 security definer RPC

-- ===== RPC（服务端事务，并发安全）=====

-- 登记兑换：一台成功一台失败由主键唯一约束 + config 行锁保证
create or replace function public.redeem(
  p_key text, p_dept text, p_name text, p_tickets int, p_by text, p_staff text
) returns json language plpgsql security definer set search_path = public as $$
declare c record; used int; t text; dg boolean := false;
begin
  select staff_code into c from public.secrets where id='main';
  if not found or c.staff_code <> p_staff then
    return json_build_object('ok',false,'err','auth','msg','口令不正确，请找负责人开权限');
  end if;
  if p_tickets is null or p_tickets < 0 then
    return json_build_object('ok',false,'err','tickets','msg','银票数不正确');
  end if;
  if exists (select 1 from public.redemptions where key=p_key) then
    return json_build_object('ok',false,'err','duplicate','msg','已兑换过，不能重复领取');
  end if;
  -- 锁住 config/main，串行化大礼份数扣减判断
  perform big_stock from public.config where id='main' for update;
  if p_tickets >= 10 then
    select count(*) into used from public.redemptions where tier='大礼';
    if used < (select big_stock from public.config where id='main') then
      t := '大礼';
    else
      t := '中礼'; dg := true;
    end if;
  elsif p_tickets >= 6 then t := '中礼';
  elsif p_tickets >= 3 then t := '小礼';
  else t := '保底礼';
  end if;
  insert into public.redemptions(key,dept,name,tickets,tier,downgraded,by)
    values (p_key,p_dept,p_name,p_tickets,t,dg,coalesce(p_by,''));
  return json_build_object('ok',true,'tier',t,'downgraded',dg);
exception when unique_violation then
  return json_build_object('ok',false,'err','duplicate','msg','已兑换过，不能重复领取');
end $$;

-- 作废（管理员）
create or replace function public.admin_void(p_key text, p_pass text)
returns json language plpgsql security definer set search_path = public as $$
declare r public.redemptions%rowtype;
begin
  if not exists (select 1 from public.secrets where id='main' and admin_pass=p_pass) then
    return json_build_object('ok',false,'err','auth','msg','管理口令不正确');
  end if;
  select * into r from public.redemptions where key=p_key;
  if not found then return json_build_object('ok',false,'err','notfound','msg','记录不存在'); end if;
  insert into public.redemptions_void values (r.*, now());
  delete from public.redemptions where key=p_key;
  return json_build_object('ok',true);
end $$;

-- 改大礼份数（管理员）
create or replace function public.admin_set_stock(p_stock int, p_pass text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.secrets where id='main' and admin_pass=p_pass) then
    return json_build_object('ok',false,'err','auth','msg','管理口令不正确');
  end if;
  if p_stock is null or p_stock < 0 then
    return json_build_object('ok',false,'err','stock','msg','份数不正确');
  end if;
  update public.config set big_stock=p_stock where id='main';
  return json_build_object('ok',true,'big_stock',p_stock);
end $$;

-- 改口令（管理员）：p_new_staff 或 p_new_admin 为空表示不改
create or replace function public.admin_set_codes(p_new_staff text, p_new_admin text, p_pass text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.secrets where id='main' and admin_pass=p_pass) then
    return json_build_object('ok',false,'err','auth','msg','管理口令不正确');
  end if;
  update public.secrets set
    staff_code = coalesce(nullif(p_new_staff,''), staff_code),
    admin_pass = coalesce(nullif(p_new_admin,''), admin_pass)
  where id='main';
  return json_build_object('ok',true);
end $$;

-- ===== 实时 =====
alter table public.redemptions replica identity full;  -- DELETE 事件带原行
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname='supabase_realtime' and schemaname='public' and tablename='redemptions') then
    alter publication supabase_realtime add table public.redemptions;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname='supabase_realtime' and schemaname='public' and tablename='config') then
    alter publication supabase_realtime add table public.config;
  end if;
end $$;

-- ===== 静态页托管：公共存储桶 =====
insert into storage.buckets (id, name, public)
values ('web', 'web', true)
on conflict (id) do nothing;
