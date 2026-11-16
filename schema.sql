-- ITM Treasurer Online / run once in Supabase SQL Editor
create extension if not exists pgcrypto;
create table public.profiles (id uuid primary key references auth.users(id) on delete cascade, full_name text not null default '', role text not null default 'member' check(role in ('member','treasurer','approver','admin')), created_at timestamptz not null default now());
create table public.campaigns (id uuid primary key default gen_random_uuid(), title text not null, amount numeric(12,2) not null check(amount>0), due_date date, created_by uuid references public.profiles(id), created_at timestamptz not null default now());
create table public.payments (id uuid primary key default gen_random_uuid(), member_id uuid not null references public.profiles(id), campaign_id uuid references public.campaigns(id), amount numeric(12,2) not null check(amount>0), paid_at timestamptz, reference text, slip_path text, status text not null default 'pending' check(status in ('pending','verified','rejected')), reviewed_by uuid references public.profiles(id), reviewed_at timestamptz, created_at timestamptz not null default now());
create unique index unique_verified_reference on public.payments(lower(reference)) where status='verified' and reference is not null and length(trim(reference))>0;
create table public.expenses (id uuid primary key default gen_random_uuid(), title text not null, category text not null default 'อื่น ๆ', amount numeric(12,2) not null check(amount>0), expense_date date not null default current_date, receipt_path text, status text not null default 'pending' check(status in ('pending','approved','rejected')), created_by uuid not null references public.profiles(id), reviewed_by uuid references public.profiles(id), reviewed_at timestamptz, created_at timestamptz not null default now());
create table public.settings (id int primary key default 1 check(id=1), opening_balance numeric(12,2) not null default 0, updated_at timestamptz not null default now());
insert into public.settings(id) values (1);
create table public.audit_log (id bigint generated always as identity primary key, actor uuid, action text not null, entity text not null, entity_id text, happened_at timestamptz not null default now());
create function public.my_role() returns text language sql stable security definer set search_path=public as $$select coalesce((select role from public.profiles where id=auth.uid()),'guest')$$;
create function public.is_finance() returns boolean language sql stable security definer set search_path=public as $$select public.my_role() in ('treasurer','admin')$$;
create function public.is_reviewer() returns boolean language sql stable security definer set search_path=public as $$select public.my_role() in ('approver','admin')$$;
create function public.on_signup() returns trigger language plpgsql security definer set search_path=public as $$begin insert into public.profiles(id,full_name) values(new.id,coalesce(new.raw_user_meta_data->>'full_name','')); return new; end$$;
create trigger auth_signup after insert on auth.users for each row execute function public.on_signup();
create function public.audit_change() returns trigger language plpgsql security definer set search_path=public as $$begin insert into public.audit_log(actor,action,entity,entity_id) values(auth.uid(),tg_op,tg_table_name,coalesce(new.id,old.id)::text); return coalesce(new,old); end$$;
create trigger payments_audit after insert or update or delete on public.payments for each row execute function public.audit_change();
create trigger expenses_audit after insert or update or delete on public.expenses for each row execute function public.audit_change();
create trigger campaigns_audit after insert or update or delete on public.campaigns for each row execute function public.audit_change();
create trigger settings_audit after update on public.settings for each row execute function public.audit_change();
-- Prevent client-side tampering with payment/expense approval, even by a treasurer.
create function public.protect_payment() returns trigger language plpgsql security definer set search_path=public as $$begin
 if tg_op='INSERT' then if new.member_id<>auth.uid() and not public.is_finance() then raise exception 'not allowed'; end if; if new.status<>'pending' or new.reviewed_by is not null then raise exception 'approval required'; end if;
 elsif tg_op='UPDATE' then
  if not public.is_finance() then raise exception 'not allowed'; end if;
  if old.status<>'pending' then raise exception 'finalized payment cannot be edited'; end if;
  if new.status='verified' and (new.reference is null or length(trim(new.reference))=0) then raise exception 'reference required for verification'; end if;
  if new.status<>old.status then new.reviewed_by:=auth.uid(); new.reviewed_at:=now(); end if;
 end if; return new; end$$;
create trigger payments_guard before insert or update on public.payments for each row execute function public.protect_payment();
create function public.protect_expense() returns trigger language plpgsql security definer set search_path=public as $$begin
 if tg_op='INSERT' then if not public.is_finance() then raise exception 'not allowed'; end if; if new.status<>'pending' then raise exception 'approval required'; end if;
 elsif tg_op='UPDATE' then
  if not public.is_reviewer() or new.created_by=auth.uid() then raise exception 'independent approver required'; end if;
  if old.status<>'pending' then raise exception 'finalized expense cannot be edited'; end if;
  if row(new.title,new.category,new.amount,new.expense_date,new.receipt_path,new.created_by) is distinct from row(old.title,old.category,old.amount,old.expense_date,old.receipt_path,old.created_by) then raise exception 'only approval status can change'; end if;
  if new.status not in ('approved','rejected') then raise exception 'approval decision required'; end if;
  new.reviewed_by:=auth.uid(); new.reviewed_at:=now();
 end if; return new; end$$;
create trigger expenses_guard before insert or update on public.expenses for each row execute function public.protect_expense();
-- Signed-in users see aggregate balances only; they cannot read other members' slips.
create function public.finance_summary() returns jsonb language sql stable security definer set search_path=public as $$select jsonb_build_object('opening',s.opening_balance,'income',(select coalesce(sum(amount),0) from public.payments where status='verified'),'expense',(select coalesce(sum(amount),0) from public.expenses where status='approved'),'pending_payments',(select count(*) from public.payments where status='pending'),'pending_expenses',(select count(*) from public.expenses where status='pending')) from public.settings s where s.id=1 and auth.uid() is not null$$;
revoke all on function public.finance_summary() from public; grant execute on function public.finance_summary() to authenticated;
alter table public.profiles enable row level security;
alter table public.campaigns enable row level security;
alter table public.payments enable row level security;
alter table public.expenses enable row level security;
alter table public.settings enable row level security;
alter table public.audit_log enable row level security;
create policy profiles_read on public.profiles for select to authenticated using(id=auth.uid() or public.is_finance() or public.is_reviewer());
-- Profile role changes are done in SQL editor by trusted administrator, not browser.
create policy campaigns_read on public.campaigns for select to authenticated using(true);
create policy campaigns_insert on public.campaigns for insert to authenticated with check(public.is_finance() and created_by=auth.uid());
create policy payments_read on public.payments for select to authenticated using(member_id=auth.uid() or public.is_finance());
create policy payments_insert on public.payments for insert to authenticated with check(member_id=auth.uid() or public.is_finance());
create policy payments_update on public.payments for update to authenticated using(public.is_finance()) with check(public.is_finance());
create policy expenses_read on public.expenses for select to authenticated using(public.is_finance() or public.is_reviewer());
create policy expenses_insert on public.expenses for insert to authenticated with check(public.is_finance() and created_by=auth.uid());
create policy expenses_update on public.expenses for update to authenticated using(public.is_reviewer() and created_by<>auth.uid()) with check(public.is_reviewer() and created_by<>auth.uid());
create policy settings_read on public.settings for select to authenticated using(public.is_finance());
create policy settings_update on public.settings for update to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
create policy audit_read on public.audit_log for select to authenticated using(public.my_role()='admin');
-- Private evidence storage. Path starts with authenticated uploader's UUID.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('evidence','evidence',false,5242880,array['image/jpeg','image/png','image/webp','application/pdf']) on conflict(id) do nothing;
create policy evidence_upload on storage.objects for insert to authenticated with check(bucket_id='evidence' and (storage.foldername(name))[1]=auth.uid()::text);
create policy evidence_read on storage.objects for select to authenticated using(bucket_id='evidence' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_finance() or public.is_reviewer()));
-- Grant the first admin manually, replacing the email below:
-- update public.profiles set role='admin' where id=(select id from auth.users where email='YOUR_EMAIL@example.com');
