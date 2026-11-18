-- Bireysel seans her zaman 1 kişilik
create or replace function public._rv_sess(p_from date, p_to date)
returns table(path text, skey text, tarih date, saat text, tur text, kap int, mids jsonb, s jsonb)
language sql stable security definer set search_path = public as $$
  select d.path, e.k, (v->>'date')::date, v->>'time', v->>'type',
         case when v->>'type' = 'bireysel' then 1
              else coalesce(nullif(v->>'kap','')::int, jsonb_array_length(coalesce(v->'memberIds','[]'::jsonb))) end,
         coalesce(v->'memberIds','[]'::jsonb), v
    from public.docs d, jsonb_each(d.data->'s') e(k, v)
   where d.path like 'w/%' and coalesce(v->>'x','0') <> '1' and v ? 'date'
     and (v->>'date') ~ '^\d{4}-\d{2}-\d{2}$' and (v->>'date')::date between p_from and p_to
$$;
revoke all on function public._rv_sess(date,date) from public, anon, authenticated;
