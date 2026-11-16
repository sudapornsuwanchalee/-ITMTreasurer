-- Apply AFTER schema.sql. Requires PostgreSQL/Supabase. Test in staging first.
create table if not exists public.bank_transactions (
 id uuid primary key default gen_random_uuid(), txn_date date not null, amount numeric(12,2) not null check(amount>0),
 direction text not null check(direction in ('credit','debit')), reference text not null,
 description text not null default '', payment_id uuid unique references public.payments(id),
 imported_by uuid not null references public.profiles(id), created_at timestamptz not null default now(),
 unique(txn_date,amount,direction,reference)
);
create table if not exists public.accounting_periods (
 id uuid primary key default gen_random_uuid(), period_end date not null unique,
 bank_balance numeric(12,2) not null, system_balance numeric(12,2) not null,
 closed_by uuid not null references public.profiles(id), closed_at timestamptz not null default now(), notes text not null default ''
);
alter table public.bank_transactions enable row level security;
alter table public.accounting_periods enable row level security;
create policy bank_read_finance on public.bank_transactions for select to authenticated using(public.is_finance());
create policy periods_read on public.accounting_periods for select to authenticated using(true);
-- All bank transaction writes happen via audited, security-definer RPCs.
create or replace function public.import_bank_transactions(items jsonb) returns int
language plpgsql security definer set search_path=public as $$
declare x jsonb; n int:=0; d date; a numeric; dir text; ref text;
begin
 if not public.is_finance() then raise exception 'treasurer required'; end if;
 if jsonb_typeof(items)<>'array' or jsonb_array_length(items)>500 then raise exception 'invalid batch'; end if;
 for x in select value from jsonb_array_elements(items) loop
  d:=(x->>'txn_date')::date; a:=(x->>'amount')::numeric; dir:=x->>'direction'; ref:=trim(x->>'reference');
  if d is null or a<=0 or dir not in ('credit','debit') or ref is null or length(ref)=0 then raise exception 'invalid statement row'; end if;
  if exists(select 1 from public.accounting_periods where period_end>=d) then raise exception 'cannot import into a closed period'; end if;
  insert into public.bank_transactions(txn_date,amount,direction,reference,description,imported_by)
  values(d,a,dir,ref,coalesce(x->>'description',''),auth.uid()) on conflict do nothing;
  if found then n:=n+1; end if;
 end loop;
 return n;
end $$;
create or replace function public.match_bank_payment(bank_id uuid,pay_id uuid) returns void
language plpgsql security definer set search_path=public as $$
declare b public.bank_transactions%rowtype; p public.payments%rowtype;
begin
 if not public.is_finance() then raise exception 'treasurer required'; end if;
 select * into b from public.bank_transactions where id=bank_id for update;
 select * into p from public.payments where id=pay_id for update;
 if b.id is null or p.id is null then raise exception 'missing transaction or payment'; end if;
 if b.direction<>'credit' or b.payment_id is not null or p.status<>'pending' or b.amount<>p.amount then raise exception 'cannot match these records'; end if;
 if exists(select 1 from public.accounting_periods where period_end>=b.txn_date) then raise exception 'period closed'; end if;
 if nullif(trim(p.reference),'') is null or lower(trim(p.reference))<>lower(trim(b.reference)) then raise exception 'reference mismatch; verify the slip reference'; end if;
 update public.payments set status='verified' where id=pay_id;
 update public.bank_transactions set payment_id=pay_id where id=bank_id;
end $$;
-- Close only when all bank rows in scope are matched or explicitly reconciled outside this MVP.
-- Debit transactions cannot be matched to expenses in this release, so closing refuses if debits exist.
create or replace function public.close_accounting_period(end_date date,bank_balance_input numeric,note_input text default '') returns void
language plpgsql security definer set search_path=public as $$
declare calculated numeric; last_end date;
begin
 if public.my_role()<>'admin' then raise exception 'admin required to close period'; end if;
 perform pg_advisory_xact_lock(739201);
 select max(period_end) into last_end from public.accounting_periods;
 if end_date is null or end_date>current_date or (last_end is not null and end_date<=last_end) then raise exception 'invalid period end'; end if;
 if exists(select 1 from public.bank_transactions where txn_date<=end_date and (last_end is null or txn_date>last_end) and (direction='debit' or payment_id is null)) then raise exception 'unreconciled statement entries: debit reconciliation is not yet supported'; end if;
 if exists(select 1 from public.payments where status='pending' and coalesce(paid_at,created_at)::date<=end_date) then raise exception 'pending payments remain'; end if;
 if exists(select 1 from public.expenses where status='pending' and expense_date<=end_date) then raise exception 'pending expenses remain'; end if;
 select s.opening_balance + coalesce((select sum(amount) from public.payments where status='verified' and coalesce(paid_at,created_at)::date<=end_date),0) - coalesce((select sum(amount) from public.expenses where status='approved' and expense_date<=end_date),0) into calculated from public.settings s where id=1;
 if calculated is distinct from bank_balance_input then raise exception 'bank and system balances differ'; end if;
 insert into public.accounting_periods(period_end,bank_balance,system_balance,closed_by,notes) values(end_date,bank_balance_input,calculated,auth.uid(),coalesce(note_input,''));
end $$;
create or replace function public.public_finance_report() returns jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object('balance',s.opening_balance+(select coalesce(sum(amount),0) from public.payments where status='verified')-(select coalesce(sum(amount),0) from public.expenses where status='approved'),
 'income',(select coalesce(sum(amount),0) from public.payments where status='verified'),
 'expense',(select coalesce(sum(amount),0) from public.expenses where status='approved'),
 'last_closed',(select max(period_end) from public.accounting_periods),
 'categories',(select coalesce(jsonb_agg(jsonb_build_object('category',category,'total',total)),'[]'::jsonb) from (select category,sum(amount) total from public.expenses where status='approved' group by category) z))
 from public.settings s where id=1 and auth.uid() is not null
$$;
revoke all on function public.import_bank_transactions(jsonb),public.match_bank_payment(uuid,uuid),public.close_accounting_period(date,numeric,text),public.public_finance_report() from public;
grant execute on function public.import_bank_transactions(jsonb),public.match_bank_payment(uuid,uuid),public.close_accounting_period(date,numeric,text),public.public_finance_report() to authenticated;
-- Audit new tables
create trigger bank_audit after insert or update or delete on public.bank_transactions for each row execute function public.audit_change();
create trigger periods_audit after insert or update or delete on public.accounting_periods for each row execute function public.audit_change();
