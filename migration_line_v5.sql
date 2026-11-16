-- Run AFTER v4 migrations. LINE accounts are allowlisted by treasurer via SQL Editor.
create table if not exists public.line_members (
 line_user_id text primary key,
 profile_id uuid not null unique references public.profiles(id) on delete cascade,
 display_name text not null,
 created_at timestamptz not null default now()
);
alter table public.line_members enable row level security;
-- No browser-facing policies. Gateway uses service_role only.
-- Existing insert guard requires auth.uid() for member inserts. Permit the trusted server gateway,
-- while still requiring a pre-approved profile ID from the LINE allowlist in the gateway.
create or replace function public.protect_payment() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_op='INSERT' then
   if coalesce(current_setting('request.jwt.claim.role',true),'') <> 'service_role'
      and new.member_id<>auth.uid() and not public.is_finance() then raise exception 'not allowed'; end if;
   if new.status<>'pending' or new.reviewed_by is not null then raise exception 'approval required'; end if;
 elsif tg_op='UPDATE' then
   if not public.is_finance() then raise exception 'not allowed'; end if;
   if old.status<>'pending' then raise exception 'finalized payment cannot be edited'; end if;
   if new.status='verified' and (new.reference is null or length(trim(new.reference))=0) then raise exception 'reference required for verification'; end if;
   if new.status<>old.status then new.reviewed_by:=auth.uid(); new.reviewed_at:=now(); end if;
 end if;
 return new;
end$$;
-- Add approved LINE member by linking to an EXISTING Supabase profile UUID:
-- insert into public.line_members(line_user_id,profile_id,display_name)
-- values ('Uxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx', 'PROFILE_UUID_HERE', 'ชื่อสมาชิก');
-- Sanitized public aggregate, callable ONLY by trusted gateway service role.
create or replace function public.itm_public_summary() returns jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object(
 'balance',s.opening_balance+(select coalesce(sum(amount),0) from public.payments where status='verified')-(select coalesce(sum(amount),0) from public.expenses where status='approved'),
 'income',(select coalesce(sum(amount),0) from public.payments where status='verified'),
 'expense',(select coalesce(sum(amount),0) from public.expenses where status='approved'),
 'last_closed',(select max(period_end) from public.accounting_periods),
 'categories',(select coalesce(jsonb_agg(jsonb_build_object('category',category,'total',total)),'[]'::jsonb) from (select category,sum(amount) total from public.expenses where status='approved' group by category) z))
 from public.settings s where s.id=1
$$;
revoke all on function public.itm_public_summary() from public,anon,authenticated;
grant execute on function public.itm_public_summary() to service_role;
