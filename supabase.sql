-- ALYA PİLATES — Supabase kurulumu (SQL Editor'a yapıştırıp Run)
create table if not exists public.docs (
  path text primary key,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.docs enable row level security;
create policy "giris yapan okur" on public.docs for select to authenticated using (true);
create policy "giris yapan ekler" on public.docs for insert to authenticated with check (true);
create policy "giris yapan gunceller" on public.docs for update to authenticated using (true) with check (true);
create policy "giris yapan siler" on public.docs for delete to authenticated using (true);
create or replace function public.merge_doc(p_path text, p_patch jsonb)
returns void language plpgsql security invoker as $$
begin
  insert into public.docs(path, data) values (p_path, '{}'::jsonb) on conflict (path) do nothing;
  update public.docs d
     set updated_at = now(),
         data = d.data || coalesce((
           select jsonb_object_agg(e.key,
             case when jsonb_typeof(e.value) = 'object' and jsonb_typeof(d.data -> e.key) = 'object'
                  then (d.data -> e.key) || e.value else e.value end)
           from jsonb_each(p_patch) e), '{}'::jsonb)
   where d.path = p_path;
end $$;
alter publication supabase_realtime add table public.docs;
