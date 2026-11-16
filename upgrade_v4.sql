-- v4: run after schema.sql and upgrade_v3.sql. TEST IN STAGING.
-- Match bank debits to approved expense records; one-to-one only.
alter table public.bank_transactions add column if not exists expense_id uuid unique references public.expenses(id);
create index if not exists bank_txn_unmatched_idx on public.bank_transactions(txn_date,direction) where payment_id is null and expense_id is null;
create or replace function public.match_bank_expense(bank_id uuid, exp_id uuid) returns void
language plpgsql security definer set search_path=public as $$
declare b public.bank_transactions%rowtype; e public.expenses%rowtype;
begin
 if not public.is_finance() then raise exception 'finance role required'; end if;
 perform pg_advisory_xact_lock(739201);
 select * into b from public.bank_transactions where id=bank_id for update;
 select * into e from public.expenses where id=exp_id for update;
 if b.id is null or e.id is null then raise exception 'record missing'; end if;
 if b.direction<>'debit' or b.payment_id is not null or b.expense_id is not null or e.status<>'approved' or b.amount<>e.amount then raise exception 'debit and approved expense must match exactly'; end if;
 if b.txn_date<>e.expense_date then raise exception 'transaction and expense dates differ; correct records before matching'; end if;
 if exists(select 1 from public.bank_transactions where expense_id=exp_id) then raise exception 'expense already reconciled'; end if;
 if exists(select 1 from public.accounting_periods where period_end>=b.txn_date) then raise exception 'period already closed'; end if;
 update public.bank_transactions set expense_id=exp_id where id=bank_id;
end $$;
-- Enforce period locks for all DML, including security-definer operations.
create or replace function public.guard_closed_ledger() returns trigger
language plpgsql security definer set search_path=public as $$
declare oldday date; newday date; last_end date;
begin
 select max(period_end) into last_end from public.accounting_periods;
 if last_end is null then return coalesce(new,old); end if;
 if tg_table_name='payments' then
   if tg_op<>'INSERT' then oldday:=coalesce(old.paid_at,old.created_at)::date; end if;
   if tg_op<>'DELETE' then newday:=coalesce(new.paid_at,new.created_at)::date; end if;
 elsif tg_table_name='expenses' then
   if tg_op<>'INSERT' then oldday:=old.expense_date; end if;
   if tg_op<>'DELETE' then newday:=new.expense_date; end if;
 elsif tg_table_name='bank_transactions' then
   if tg_op<>'INSERT' then oldday:=old.txn_date; end if;
   if tg_op<>'DELETE' then newday:=new.txn_date; end if;
 end if;
 if (oldday is not null and oldday<=last_end) or (newday is not null and newday<=last_end) then raise exception 'closed period is immutable; use a new-period adjustment'; end if;
 return coalesce(new,old);
end $$;
drop trigger if exists payment_period_lock on public.payments;
create trigger payment_period_lock before insert or update or delete on public.payments for each row execute function public.guard_closed_ledger();
drop trigger if exists expense_period_lock on public.expenses;
create trigger expense_period_lock before insert or update or delete on public.expenses for each row execute function public.guard_closed_ledger();
drop trigger if exists bank_period_lock on public.bank_transactions;
create trigger bank_period_lock before insert or update or delete on public.bank_transactions for each row execute function public.guard_closed_ledger();
-- Prevent any modifications to recorded period snapshots from the client.
create or replace function public.prevent_period_mutation() returns trigger language plpgsql as $$begin raise exception 'closed accounting periods cannot be edited'; end $$;
drop trigger if exists period_immutable on public.accounting_periods;
create trigger period_immutable before update or delete on public.accounting_periods for each row execute function public.prevent_period_mutation();
-- Enforce reconciliation completeness and bank balance equality at close.
create or replace function public.close_accounting_period(end_date date,bank_balance_input numeric,note_input text default '') returns void
language plpgsql security definer set search_path=public as $$
declare calculated numeric; last_end date;
begin
 if public.my_role()<>'admin' then raise exception 'admin required to close period'; end if;
 perform pg_advisory_xact_lock(739201);
 select max(period_end) into last_end from public.accounting_periods;
 if end_date is null or end_date>current_date or (last_end is not null and end_date<=last_end) then raise exception 'invalid period end'; end if;
 if exists(select 1 from public.bank_transactions where txn_date<=end_date and (last_end is null or txn_date>last_end) and ((direction='credit' and payment_id is null) or (direction='debit' and expense_id is null))) then raise exception 'unmatched bank transactions remain'; end if;
 if exists(select 1 from public.payments p where p.status='verified' and coalesce(p.paid_at,p.created_at)::date<=end_date and not exists(select 1 from public.bank_transactions b where b.payment_id=p.id)) then raise exception 'verified payments without bank match remain'; end if;
 if exists(select 1 from public.expenses e where e.status='approved' and e.expense_date<=end_date and not exists(select 1 from public.bank_transactions b where b.expense_id=e.id)) then raise exception 'approved expenses without bank match remain'; end if;
 if exists(select 1 from public.payments where status='pending' and coalesce(paid_at,created_at)::date<=end_date) then raise exception 'pending payments remain'; end if;
 if exists(select 1 from public.expenses where status='pending' and expense_date<=end_date) then raise exception 'pending expenses remain'; end if;
 select s.opening_balance + coalesce((select sum(amount) from public.payments where status='verified' and coalesce(paid_at,created_at)::date<=end_date),0) - coalesce((select sum(amount) from public.expenses where status='approved' and expense_date<=end_date),0) into calculated from public.settings s where id=1;
 if calculated is distinct from bank_balance_input then raise exception 'bank balance differs from system ledger'; end if;
 insert into public.accounting_periods(period_end,bank_balance,system_balance,closed_by,notes) values(end_date,bank_balance_input,calculated,auth.uid(),coalesce(note_input,''));
end $$;
-- Disallow editing opening balance once a period has closed.
create or replace function public.lock_opening_balance() returns trigger language plpgsql as $$begin if exists(select 1 from public.accounting_periods) then raise exception 'opening balance locked after first close'; end if; return new; end $$;
drop trigger if exists settings_close_lock on public.settings;
create trigger settings_close_lock before update on public.settings for each row execute function public.lock_opening_balance();
revoke all on function public.match_bank_expense(uuid,uuid) from public;
grant execute on function public.match_bank_expense(uuid,uuid) to authenticated;
