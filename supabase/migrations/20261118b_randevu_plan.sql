-- ALYA · Online randevu v2: seanslar Plan'dan (docs w/*) gelir, randevu alan üye seansın içine yazılır.

-- Plan'daki seanslar (tarih aralığında)
create or replace function public._rv_sess(p_from date, p_to date)
returns table(path text, skey text, tarih date, saat text, tur text, kap int, mids jsonb, s jsonb)
language sql stable security definer set search_path = public as $$
  select d.path, e.k, (v->>'date')::date, v->>'time', v->>'type',
         coalesce(nullif(v->>'kap','')::int, case when v->>'type' = 'bireysel' then 1 else jsonb_array_length(coalesce(v->'memberIds','[]'::jsonb)) end),
         coalesce(v->'memberIds','[]'::jsonb), v
    from public.docs d, jsonb_each(d.data->'s') e(k, v)
   where d.path like 'w/%' and coalesce(v->>'x','0') <> '1' and v ? 'date'
     and (v->>'date') ~ '^\d{4}-\d{2}-\d{2}$' and (v->>'date')::date between p_from and p_to
$$;

-- seanstaki kişi sayısı: seans üyeleri + (henüz seansa yazılmamış) aktif randevular
create or replace function public._rv_dolu2(p_tarih date, p_saat text, p_tur text, p_mids jsonb) returns int
language sql stable security definer set search_path = public as $$
  select jsonb_array_length(p_mids) + (select count(*) from public.rv_randevu r
     where r.tarih = p_tarih and r.saat = p_saat and r.tur = p_tur and r.durum = 'aktif'
       and not (p_mids ? r.uye_id))::int
$$;

create or replace function public.rv_bilgi(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u text; k jsonb; nowl timestamp; ileri int; iptal int; ad text; ses jsonb; ran jsonb; acik boolean;
begin
  u := public._rv_uye(p_token);
  if u is null then return jsonb_build_object('ok', false, 'hata', 'gecersiz'); end if;
  k := coalesce(public._rv_ayar()->'k', '{}'::jsonb);
  ileri := coalesce((k->>'ileri')::int, 14); iptal := coalesce((k->>'iptal')::int, 6); nowl := public._rv_now();
  acik := coalesce((k->>'acik')::int, 0) = 1;
  select data->'m'->u->>'name' into ad from public.docs where path = 'cfg/m';
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'tarih', r.tarih, 'saat', r.saat, 'tur', r.tur,
           'iptal', (r.tarih + r.saat::time) - make_interval(hours => iptal) > nowl) order by r.tarih, r.saat), '[]')
    into ran from public.rv_randevu r where r.uye_id = u and r.durum = 'aktif' and (r.tarih + r.saat::time) > nowl;
  select coalesce(jsonb_agg(x order by x->>'tarih', x->>'saat'), '[]') into ses from (
    select jsonb_build_object('tarih', q.tarih, 'saat', q.saat, 'tur', q.tur, 'kap', q.kap,
             'dolu', public._rv_dolu2(q.tarih, q.saat, q.tur, q.mids),
             'benim', (q.mids ? u) or exists (select 1 from public.rv_randevu r where r.uye_id = u and r.durum = 'aktif' and r.tarih = q.tarih and r.saat = q.saat)) x
      from public._rv_sess(nowl::date, nowl::date + ileri) q
     where q.saat ~ '^\d{2}:\d{2}$' and (q.tarih + q.saat::time) > nowl and q.kap > 0) z;
  return jsonb_build_object('ok', true, 'ad', coalesce(ad, ''), 'acik', acik, 'iptalSaat', iptal, 'ileriGun', ileri,
    'kalan', jsonb_build_object('grup', public._rv_kalan(u, 'grup'), 'bireysel', public._rv_kalan(u, 'bireysel')),
    'randevular', ran, 'seanslar', case when acik then ses else '[]'::jsonb end);
end $$;

create or replace function public.rv_al(p_token text, p_tarih date, p_saat text, p_tur text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare u text; k jsonb; nowl timestamp; ileri int; q record; dolu int; n int; p text;
begin
  u := public._rv_uye(p_token);
  if u is null then return jsonb_build_object('ok', false, 'mesaj', 'Bağlantı geçersiz. Stüdyodan yeni bağlantı iste.'); end if;
  perform pg_advisory_xact_lock(hashtext('rv-uye:' || u));
  perform pg_advisory_xact_lock(hashtext('rv-slot:' || p_tarih || ' ' || p_saat || ' ' || p_tur));
  k := coalesce(public._rv_ayar()->'k', '{}'::jsonb); nowl := public._rv_now();
  ileri := coalesce((k->>'ileri')::int, 14);
  if coalesce((k->>'acik')::int, 0) <> 1 then return jsonb_build_object('ok', false, 'mesaj', 'Online randevu şu an kapalı.'); end if;
  if (p_tarih + p_saat::time) <= nowl then return jsonb_build_object('ok', false, 'mesaj', 'Bu seansın saati geçti.'); end if;
  if p_tarih > nowl::date + ileri then return jsonb_build_object('ok', false, 'mesaj', 'En fazla ' || ileri || ' gün sonrasına randevu alınabilir.'); end if;
  if exists (select 1 from public.rv_randevu where uye_id = u and tarih = p_tarih and saat = p_saat and durum = 'aktif') then
    return jsonb_build_object('ok', false, 'mesaj', 'Bu saate zaten randevun var.'); end if;
  if public._rv_kalan(u, p_tur) <= 0 then
    return jsonb_build_object('ok', false, 'mesaj', case p_tur when 'grup' then 'Grup ders hakkın kalmadı.' else 'Bireysel ders hakkın kalmadı.' end || ' Stüdyo ile iletişime geç.'); end if;
  -- boş yeri olan ilk seans; doküman satırı kilitlenir
  n := 0;
  for p in select distinct z.path from public._rv_sess(p_tarih, p_tarih) z where z.saat = p_saat and z.tur = p_tur order by 1 loop
    perform 1 from public.docs where path = p for update;
  end loop;
  for q in select * from public._rv_sess(p_tarih, p_tarih) z where z.saat = p_saat and z.tur = p_tur order by z.path, z.skey loop
    n := n + 1;
    if q.mids ? u then return jsonb_build_object('ok', false, 'mesaj', 'Bu seansta zaten varsın.'); end if;
    dolu := public._rv_dolu2(q.tarih, q.saat, q.tur, q.mids);
    if dolu < q.kap then
      insert into public.rv_randevu (uye_id, tarih, saat, tur) values (u, p_tarih, p_saat, p_tur);
      update public.docs set data = jsonb_set(jsonb_set(data, array['s', q.skey, 'memberIds'], q.mids || to_jsonb(u)),
                                              array['s', q.skey, 'rv'], coalesce(q.s->'rv', '{}'::jsonb) || jsonb_build_object(u, 1)),
                             updated_at = now()
       where path = q.path;
      return jsonb_build_object('ok', true, 'mesaj', 'Randevun alındı.');
    end if;
  end loop;
  if n = 0 then return jsonb_build_object('ok', false, 'mesaj', 'Bu saatte açık seans yok.'); end if;
  return jsonb_build_object('ok', false, 'mesaj', 'Bu seans doldu.');
end $$;

create or replace function public.rv_iptal(p_token text, p_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare u text; r public.rv_randevu; iptal int; q record; has_att boolean;
begin
  u := public._rv_uye(p_token);
  if u is null then return jsonb_build_object('ok', false, 'mesaj', 'Bağlantı geçersiz.'); end if;
  select * into r from public.rv_randevu where id = p_id and uye_id = u and durum = 'aktif' for update;
  if not found then return jsonb_build_object('ok', false, 'mesaj', 'Randevu bulunamadı.'); end if;
  iptal := coalesce((public._rv_ayar()->'k'->>'iptal')::int, 6);
  if (r.tarih + r.saat::time) - make_interval(hours => iptal) <= public._rv_now() then
    return jsonb_build_object('ok', false, 'mesaj', 'Derse ' || iptal || ' saatten az kaldığı için iptal edilemez. Stüdyoyu ara.'); end if;
  update public.rv_randevu set durum = 'iptal', iptal_at = now(), iptal_eden = 'uye' where id = r.id;
  -- üyeyi seanstan çıkar (yoklaması alınmadıysa)
  for q in select * from public._rv_sess(r.tarih, r.tarih) z where z.saat = r.saat and z.tur = r.tur and z.mids ? u loop
    perform 1 from public.docs where path = q.path for update;
    select exists (select 1 from public.docs d, jsonb_each(d.data->'a') e(k, a)
                    where d.path = q.path and coalesce(a->>'x','0') <> '1' and a->>'sid' = q.s->>'id' and a->>'mid' = u and coalesce(a->>'v','') <> '') into has_att;
    if not has_att then
      update public.docs set data = jsonb_set(jsonb_set(data, array['s', q.skey, 'memberIds'],
                               coalesce((select jsonb_agg(x) from jsonb_array_elements(q.mids) x where x <> to_jsonb(u)), '[]'::jsonb)),
                               array['s', q.skey, 'rv'], coalesce(q.s->'rv', '{}'::jsonb) - u),
                             updated_at = now()
       where path = q.path;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'mesaj', 'Randevun iptal edildi.');
end $$;

-- kısa bağlantı anahtarı (10 karakter)
create or replace function public.rv_link(p_uye text) returns text
language plpgsql volatile security definer set search_path = public, extensions as $$
declare t text; b bytea; i int; c text := 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
begin
  if coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin' then raise exception 'Yetki yok'; end if;
  if not exists (select 1 from public.docs where path = 'cfg/m' and data->'m'->p_uye ? 'name' and coalesce(data->'m'->p_uye->>'x','0') <> '1') then
    raise exception 'Pilates üyesi bulunamadı';
  end if;
  b := extensions.gen_random_bytes(10); t := '';
  for i in 0..9 loop t := t || substr(c, (get_byte(b, i) % length(c)) + 1, 1); end loop;
  insert into public.rv_erisim (uye_id, token_hash) values (p_uye, encode(extensions.digest(t, 'sha256'), 'hex'))
  on conflict (uye_id) do update set token_hash = excluded.token_hash, created_at = now(), created_by = auth.uid();
  return t;
end $$;

revoke all on function public._rv_sess(date,date), public._rv_dolu2(date,text,text,jsonb) from public, anon, authenticated;
