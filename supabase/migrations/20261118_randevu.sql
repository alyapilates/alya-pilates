-- ALYA · Online randevu (Pilates)
-- Üyeler gerçek hesap açmaz; WhatsApp'tan gelen kişisel bağlantıdaki anahtarla yalnızca
-- aşağıdaki rv_bilgi / rv_al / rv_iptal fonksiyonlarını çağırabilir.
-- Kontenjan kontrolü veritabanında, kilit altında yapılır (aynı anda gelen istekler sıraya girer).

-- 1) Üye erişim anahtarları (anahtarın kendisi değil, SHA-256 özeti saklanır)
create table if not exists public.rv_erisim (
  uye_id     text primary key,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);
alter table public.rv_erisim enable row level security;
drop policy if exists "rv_erisim yonetici okur" on public.rv_erisim;
create policy "rv_erisim yonetici okur" on public.rv_erisim for select to authenticated
  using (coalesce(auth.jwt()->'app_metadata'->>'role','') = 'admin');
drop policy if exists "rv_erisim yonetici siler" on public.rv_erisim;
create policy "rv_erisim yonetici siler" on public.rv_erisim for delete to authenticated
  using (coalesce(auth.jwt()->'app_metadata'->>'role','') = 'admin');

-- 2) Randevular
create table if not exists public.rv_randevu (
  id         uuid primary key default gen_random_uuid(),
  uye_id     text not null,
  tarih      date not null,
  saat       text not null check (saat ~ '^\d{2}:\d{2}$'),
  tur        text not null check (tur in ('grup','bireysel')),
  durum      text not null default 'aktif' check (durum in ('aktif','iptal')),
  created_at timestamptz not null default now(),
  iptal_at   timestamptz,
  iptal_eden text
);
create unique index if not exists rv_randevu_tekil on public.rv_randevu (uye_id, tarih, saat) where durum = 'aktif';
create index if not exists rv_randevu_slot on public.rv_randevu (tarih, saat, tur) where durum = 'aktif';
alter table public.rv_randevu enable row level security;
drop policy if exists "rv_randevu giris yapan okur" on public.rv_randevu;
create policy "rv_randevu giris yapan okur" on public.rv_randevu for select to authenticated using (true);
drop policy if exists "rv_randevu yonetici gunceller" on public.rv_randevu;
create policy "rv_randevu yonetici gunceller" on public.rv_randevu for update to authenticated
  using (coalesce(auth.jwt()->'app_metadata'->>'role','') = 'admin')
  with check (coalesce(auth.jwt()->'app_metadata'->>'role','') = 'admin');
drop policy if exists "rv_randevu yonetici siler" on public.rv_randevu;
create policy "rv_randevu yonetici siler" on public.rv_randevu for delete to authenticated
  using (coalesce(auth.jwt()->'app_metadata'->>'role','') = 'admin');

-- 3) Yardımcılar (dışarıdan çağrılamaz)
create or replace function public._rv_now() returns timestamp language sql stable as
$$ select (now() at time zone 'Europe/Istanbul') $$;

create or replace function public._rv_uye(p_token text) returns text
language sql stable security definer set search_path = public, extensions as $$
  select uye_id from public.rv_erisim
  where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex')
$$;

create or replace function public._rv_ayar() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select data from public.docs where path = 'rv/sablon'), '{}'::jsonb)
$$;

-- Pilates üyesinin bu türdeki kalan ders hakkı:
-- paket toplamı − yoklamada sayılan dersler (geldi/gelmedi) − henüz yoklaması alınmamış aktif randevular
create or replace function public._rv_kalan(p_uye text, p_tur text) returns int
language plpgsql stable security definer set search_path = public as $$
declare tot int; used int; pend int;
begin
  select coalesce(sum((v->>'total')::int), 0) into tot
    from public.docs d, jsonb_each(d.data->'p') e(k, v)
   where d.path = 'qp/' || p_uye and coalesce(v->>'x','0') <> '1' and v->>'type' = p_tur;
  select count(*) into used
    from public.docs d, jsonb_each(d.data->'a') e(k, a)
   where d.path like 'w/%' and coalesce(a->>'x','0') <> '1' and a->>'mid' = p_uye and a->>'v' in ('k','y')
     and d.data->'s'->(a->>'sid')->>'type' = p_tur;
  select count(*) into pend
    from public.rv_randevu r
   where r.uye_id = p_uye and r.tur = p_tur and r.durum = 'aktif'
     and not exists (
       select 1 from public.docs d, jsonb_each(d.data->'s') e(k, s)
        where d.path like 'w/%' and coalesce(s->>'x','0') <> '1'
          and s->>'date' = r.tarih::text and s->>'time' = r.saat and s->>'type' = r.tur
          and exists (select 1 from jsonb_each(d.data->'a') e2(k2, a)
                       where coalesce(a->>'x','0') <> '1' and a->>'sid' = s->>'id' and a->>'mid' = p_uye and a->>'v' in ('k','y')));
  return tot - used - pend;
end $$;

-- Bir seansın doluluğu: aktif randevular + yöneticinin o seansa elle eklediği (randevusu olmayan) üyeler
create or replace function public._rv_dolu(p_tarih date, p_saat text, p_tur text) returns int
language sql stable security definer set search_path = public as $$
  with r as (select uye_id from public.rv_randevu where tarih = p_tarih and saat = p_saat and tur = p_tur and durum = 'aktif'),
       m as (select distinct jsonb_array_elements_text(s->'memberIds') uye_id
               from public.docs d, jsonb_each(d.data->'s') e(k, s)
              where d.path like 'w/%' and coalesce(s->>'x','0') <> '1'
                and s->>'date' = p_tarih::text and s->>'time' = p_saat and s->>'type' = p_tur)
  select (select count(*) from r)::int + (select count(*) from m where uye_id not in (select uye_id from r))::int
$$;

-- 4) Yönetici: üyeye kişisel bağlantı anahtarı üretir (eskisi geçersiz olur)
create or replace function public.rv_link(p_uye text) returns text
language plpgsql volatile security definer set search_path = public, extensions as $$
declare t text;
begin
  if coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin' then raise exception 'Yetki yok'; end if;
  if not exists (select 1 from public.docs where path = 'cfg/m' and data->'m'->p_uye ? 'name' and coalesce(data->'m'->p_uye->>'x','0') <> '1') then
    raise exception 'Pilates üyesi bulunamadı';
  end if;
  t := translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/=', '-_');
  insert into public.rv_erisim (uye_id, token_hash) values (p_uye, encode(extensions.digest(t, 'sha256'), 'hex'))
  on conflict (uye_id) do update set token_hash = excluded.token_hash, created_at = now(), created_by = auth.uid();
  return t;
end $$;

-- 5) Üye: bilgiler + seanslar
create or replace function public.rv_bilgi(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u text; ay jsonb; k jsonb; nowl timestamp; ileri int; iptal int; ad text; ses jsonb; ran jsonb;
begin
  u := public._rv_uye(p_token);
  if u is null then return jsonb_build_object('ok', false, 'hata', 'gecersiz'); end if;
  ay := public._rv_ayar(); k := coalesce(ay->'k', '{}'::jsonb);
  ileri := coalesce((k->>'ileri')::int, 14); iptal := coalesce((k->>'iptal')::int, 6); nowl := public._rv_now();
  select data->'m'->u->>'name' into ad from public.docs where path = 'cfg/m';
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'tarih', r.tarih, 'saat', r.saat, 'tur', r.tur,
           'iptal', (r.tarih + r.saat::time) - make_interval(hours => iptal) > nowl) order by r.tarih, r.saat), '[]')
    into ran from public.rv_randevu r where r.uye_id = u and r.durum = 'aktif' and (r.tarih + r.saat::time) > nowl;
  select coalesce(jsonb_agg(x order by x->>'tarih', x->>'saat'), '[]') into ses from (
    select jsonb_build_object('tarih', g.d::date, 'saat', v->>'t', 'tur', v->>'tur', 'kap', (v->>'k')::int,
             'dolu', public._rv_dolu(g.d::date, v->>'t', v->>'tur'),
             'benim', exists (select 1 from public.rv_randevu r where r.uye_id = u and r.durum = 'aktif' and r.tarih = g.d::date and r.saat = v->>'t')) x
      from generate_series(nowl::date, nowl::date + ileri, interval '1 day') g(d),
           jsonb_each(coalesce(ay->'s', '{}'::jsonb)) e(id, v)
     where coalesce(v->>'x','0') <> '1' and (v->>'g')::int = extract(isodow from g.d)::int - 1
       and (g.d::date + (v->>'t')::time) > nowl) q;
  return jsonb_build_object('ok', true, 'ad', coalesce(ad, ''), 'acik', coalesce((k->>'acik')::int, 0) = 1,
    'iptalSaat', iptal, 'ileriGun', ileri,
    'kalan', jsonb_build_object('grup', public._rv_kalan(u, 'grup'), 'bireysel', public._rv_kalan(u, 'bireysel')),
    'randevular', ran, 'seanslar', case when coalesce((k->>'acik')::int, 0) = 1 then ses else '[]'::jsonb end);
end $$;

-- 6) Üye: randevu al (kilitli kontenjan kontrolü)
create or replace function public.rv_al(p_token text, p_tarih date, p_saat text, p_tur text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare u text; ay jsonb; k jsonb; nowl timestamp; ileri int; kap int; dolu int;
begin
  u := public._rv_uye(p_token);
  if u is null then return jsonb_build_object('ok', false, 'mesaj', 'Bağlantı geçersiz. Stüdyodan yeni bağlantı iste.'); end if;
  -- aynı üyenin iki isteği ve aynı seansa gelen istekler sıraya girer
  perform pg_advisory_xact_lock(hashtext('rv-uye:' || u));
  perform pg_advisory_xact_lock(hashtext('rv-slot:' || p_tarih || ' ' || p_saat || ' ' || p_tur));
  ay := public._rv_ayar(); k := coalesce(ay->'k', '{}'::jsonb); nowl := public._rv_now();
  ileri := coalesce((k->>'ileri')::int, 14);
  if coalesce((k->>'acik')::int, 0) <> 1 then return jsonb_build_object('ok', false, 'mesaj', 'Online randevu şu an kapalı.'); end if;
  if (p_tarih + p_saat::time) <= nowl then return jsonb_build_object('ok', false, 'mesaj', 'Bu seansın saati geçti.'); end if;
  if p_tarih > nowl::date + ileri then return jsonb_build_object('ok', false, 'mesaj', 'En fazla ' || ileri || ' gün sonrasına randevu alınabilir.'); end if;
  select max((v->>'k')::int) into kap from jsonb_each(coalesce(ay->'s', '{}'::jsonb)) e(id, v)
   where coalesce(v->>'x','0') <> '1' and (v->>'g')::int = extract(isodow from p_tarih)::int - 1 and v->>'t' = p_saat and v->>'tur' = p_tur;
  if kap is null then return jsonb_build_object('ok', false, 'mesaj', 'Böyle bir seans yok.'); end if;
  if exists (select 1 from public.rv_randevu where uye_id = u and tarih = p_tarih and saat = p_saat and durum = 'aktif') then
    return jsonb_build_object('ok', false, 'mesaj', 'Bu saate zaten randevun var.'); end if;
  if public._rv_kalan(u, p_tur) <= 0 then
    return jsonb_build_object('ok', false, 'mesaj', case p_tur when 'grup' then 'Grup ders hakkın kalmadı.' else 'Bireysel ders hakkın kalmadı.' end || ' Stüdyo ile iletişime geç.'); end if;
  dolu := public._rv_dolu(p_tarih, p_saat, p_tur);
  if dolu >= kap then return jsonb_build_object('ok', false, 'mesaj', 'Bu seans doldu.'); end if;
  insert into public.rv_randevu (uye_id, tarih, saat, tur) values (u, p_tarih, p_saat, p_tur);
  return jsonb_build_object('ok', true, 'mesaj', 'Randevun alındı.');
end $$;

-- 7) Üye: randevu iptal
create or replace function public.rv_iptal(p_token text, p_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare u text; r public.rv_randevu; iptal int;
begin
  u := public._rv_uye(p_token);
  if u is null then return jsonb_build_object('ok', false, 'mesaj', 'Bağlantı geçersiz.'); end if;
  select * into r from public.rv_randevu where id = p_id and uye_id = u and durum = 'aktif' for update;
  if not found then return jsonb_build_object('ok', false, 'mesaj', 'Randevu bulunamadı.'); end if;
  iptal := coalesce((public._rv_ayar()->'k'->>'iptal')::int, 6);
  if (r.tarih + r.saat::time) - make_interval(hours => iptal) <= public._rv_now() then
    return jsonb_build_object('ok', false, 'mesaj', 'Derse ' || iptal || ' saatten az kaldığı için iptal edilemez. Stüdyoyu ara.'); end if;
  update public.rv_randevu set durum = 'iptal', iptal_at = now(), iptal_eden = 'uye' where id = r.id;
  return jsonb_build_object('ok', true, 'mesaj', 'Randevun iptal edildi.');
end $$;

-- 8) Yetkiler
revoke all on function public._rv_now(), public._rv_uye(text), public._rv_ayar(), public._rv_kalan(text,text),
  public._rv_dolu(date,text,text) from public, anon, authenticated;
revoke all on function public.rv_link(text) from public, anon;
grant execute on function public.rv_link(text) to authenticated;
revoke all on function public.rv_bilgi(text), public.rv_al(text,date,text,text), public.rv_iptal(text,uuid) from public;
grant execute on function public.rv_bilgi(text), public.rv_al(text,date,text,text), public.rv_iptal(text,uuid) to anon, authenticated;
alter function public._rv_now() set search_path = public;
